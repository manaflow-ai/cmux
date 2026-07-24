#if os(iOS)
@preconcurrency public import AVFoundation
import Foundation

/// Owns the `AVAudioEngine` + shared `AVAudioSession` lifecycle OFF the main
/// actor for ``ComposerDictationController``.
///
/// `AVAudioSession.setActive(_:)`, `AVAudioEngine.start()`, and their stop
/// counterparts are synchronous audio-hardware calls that block their caller
/// roughly 100-300ms each. ``ComposerDictationController`` is `@MainActor`, so
/// running them inline froze the composer mic button's press animation on every
/// toggle (https://github.com/manaflow-ai/cmux/issues/6284). This owner runs
/// every one of those calls on its own serial queue, so the main actor only ever
/// ENQUEUES the work — it never blocks on the audio hardware.
///
/// Concurrency: a private serial `DispatchQueue` plus `@unchecked Sendable`, NOT
/// an `actor` — a deliberate low-level carve-out (lint:allow serial-audio-queue),
/// matching the established AVFoundation-session-on-a-serial-queue pattern already
/// used for capture in `QRCodeCaptureController` (Apple's own AVFoundation sample
/// code drives capture/audio sessions from a dedicated serial dispatch queue, not
/// Swift concurrency). Two concrete reasons an actor is the wrong tool here:
///   1. `setActive`/`engine.start`/`engine.stop` are SYNCHRONOUS, ~100-300ms
///      blocking hardware calls. On an actor they would block a cooperative-pool
///      thread (the pool is sized to the core count), risking starvation/priority
///      inversion across the app; a dedicated serial queue confines the block to
///      its own thread.
///   2. The supersession invariant needs ``stop()`` enqueued SYNCHRONOUSLY and in
///      deterministic FIFO order relative to ``start(tapBlock:onReady:)``, directly
///      from the `@MainActor` controller's synchronous teardown path. A serial
///      `DispatchQueue.async` guarantees that; a cross-actor `await` (which the
///      synchronous controller could only reach via `Task { await … }`) gives no
///      deterministic ordering between independently-scheduled tasks.
/// The mutable state (`engine`, `isActive`) is touched ONLY on ``queue`` — every
/// entry point hops through it, and ``teardownLocked()`` asserts the invariant with
/// `dispatchPrecondition` — so the type is data-race-free despite wrapping the
/// non-Sendable `AVAudioEngine`. Callers pass `@Sendable` closures and hop back to
/// the main actor inside them, exactly like the controller's authorization and
/// recognition callbacks. Because ``queue`` is serial and FIFO, a ``stop()``
/// enqueued while a ``start(tapBlock:onReady:)`` is mid-flight is always ordered
/// AFTER that start's activation and BEFORE any later start's activation, so the
/// engine can never be double-started or leak a tap across a rapid stop/restart.
public final class ComposerDictationAudioEngine: @unchecked Sendable {
    /// The serial queue that owns every audio-hardware call. All mutable state
    /// below is confined to it, which is what makes the `@unchecked Sendable`
    /// conformance sound; ``teardownLocked()`` asserts execution lands here.
    private let queue = DispatchQueue(label: "com.cmux.composer.dictation-audio")

    /// The audio engine capturing microphone buffers. Created once and reused
    /// across start/stop cycles; its input-node tap is installed on start and
    /// removed on every teardown. Touched only on ``queue``.
    private let engine = AVAudioEngine()

    /// Whether THIS owner currently holds the shared `AVAudioSession` active.
    /// Gates teardown so a stop with nothing activated never powers up the mic
    /// route (accessing `inputNode` does) or interrupts other apps' audio with a
    /// spurious `setActive(false, .notifyOthersOnDeactivation)`. Touched only on
    /// ``queue``.
    private var isActive = false

    public init() {}

    /// Activate the audio session and start the engine off the main actor,
    /// installing `tapBlock` on the input node. Reports the outcome through
    /// `onReady` (`true` = engine running, `false` = setup failed), called on
    /// ``queue`` — the caller hops to the main actor inside it. On any failure the
    /// partial setup is torn down before `onReady(false)`, so the session is never
    /// left active after a failed start.
    ///
    /// - Parameters:
    ///   - tapBlock: Installed on the input node; invoked on the realtime audio
    ///     render thread for every captured buffer. Must be `@Sendable`.
    ///   - onReady: Called once on ``queue`` with whether the engine is running.
    public func start(
        tapBlock: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onReady: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            do {
                let session = AVAudioSession.sharedInstance()
                // Record-only category for speech-to-text. `.duckOthers` is NOT
                // valid for `.record`, and `.notifyOthersOnDeactivation` is only
                // valid on deactivation, so both are omitted here; passing them
                // throws on OSes that enforce the documented restrictions.
                try session.setCategory(.record, mode: .measurement)
                try session.setActive(true)
                // Set before later setup so a failure still deactivates in teardown.
                isActive = true

                let inputNode = engine.inputNode
                let format = inputNode.outputFormat(forBus: 0)
                // Validate the input format; an invalid one makes `installTap`
                // raise an uncatchable Obj-C exception.
                guard format.channelCount > 0, format.sampleRate > 0 else {
                    teardownLocked()
                    onReady(false)
                    return
                }
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tapBlock)
                engine.prepare()
                try engine.start()
                onReady(true)
            } catch {
                teardownLocked()
                onReady(false)
            }
        }
    }

    /// Stop the engine, remove the input tap, and deactivate the audio session
    /// off the main actor. Idempotent and safe to call from any state any number
    /// of times; serialized after any in-flight ``start(tapBlock:onReady:)`` so a
    /// stop enqueued during spin-up always tears the engine back down.
    public func stop() {
        queue.async { [self] in
            teardownLocked()
        }
    }

    /// Stop the engine, remove the tap, and deactivate the session. MUST run on
    /// ``queue``. A no-op unless this owner activated the session, so a stop with
    /// nothing active never touches the audio system.
    private func teardownLocked() {
        // Self-enforce the isolation contract: this method (and the mutable state it
        // touches) is only data-race-free because it runs on `queue`. Trap loudly if
        // a future caller ever reaches it off-queue rather than silently racing.
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive else { return }
        isActive = false
        if engine.isRunning {
            engine.stop()
        }
        // The tap must be removed whether or not the engine was running, so a
        // failed start that installed the tap before `engine.start()` threw does
        // not leak it onto the input node.
        engine.inputNode.removeTap(onBus: 0)
        // Deactivate so other audio (and the system) reclaim the session. Failure
        // here is non-fatal: the engine is already stopped.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
