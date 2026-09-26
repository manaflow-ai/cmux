import AVFoundation
import Foundation

/// Owns the `AVAudioEngine` lifecycle OFF the main actor for dictation sessions.
///
/// `AVAudioEngine.start()`/`stop()` are synchronous audio-hardware calls that
/// block their caller roughly 100-300 ms each. The dictation controller is
/// `@MainActor`, so running them inline would hitch the UI on every trigger.
/// This owner runs every hardware call on its own serial queue — the main
/// actor only ever enqueues work.
///
/// Concurrency: a private serial `DispatchQueue` plus `@unchecked Sendable`, NOT
/// an actor (lint:allow serial-audio-queue) — the same deliberate low-level
/// carve-out as `ComposerDictationAudioEngine` in `CmuxMobileSupport`:
/// `start`/`stop` are synchronous ~100-300 ms hardware calls that would block a
/// cooperative-pool thread on an actor, and teardown must be FIFO-ordered
/// against an in-flight start, which the serial queue guarantees and a
/// cross-actor `await` does not. Mutable state (`engine`, `isActive`) is touched
/// only on `queue` (asserted with `dispatchPrecondition`), so the type is
/// data-race-free despite wrapping the non-Sendable engine.
final class DictationAudioEngine: @unchecked Sendable {
    /// Serial queue owning every audio-hardware call and the mutable state below.
    private let queue = DispatchQueue(label: "com.cmuxterm.dictation-audio")

    /// The capture engine; created once, tap installed on start, removed on teardown.
    private let engine = AVAudioEngine()

    /// Whether this owner currently has the engine running. Gates teardown so a
    /// stop with nothing running never touches the audio system. Touched only on
    /// `queue`.
    private var isActive = false

    /// Starts the engine off the main actor, installing `tapBlock` on the input
    /// node. Reports the outcome through `onReady` on `queue` (`true` = running);
    /// on failure the partial setup is torn down before reporting.
    ///
    /// - Parameters:
    ///   - tapBlock: Installed on the input node; invoked on the realtime audio
    ///     render thread for every captured buffer. Must be `@Sendable`.
    ///   - onReady: Called once on `queue` with whether the engine is running.
    func start(
        tapBlock: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onReady: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            guard !isActive else {
                onReady(true)
                return
            }
            let inputNode = engine.inputNode
            // Reinstalling over a stale tap crashes; this owner never leaves one
            // behind (teardown removes it), but a defensive reset is cheap.
            inputNode.removeTap(onBus: 0)
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                teardownLocked()
                onReady(false)
                return
            }
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat, block: tapBlock)
            do {
                try engine.start()
                isActive = true
                onReady(true)
            } catch {
                teardownLocked()
                onReady(false)
            }
        }
    }

    /// Stops the engine and removes the input tap off the main actor. Idempotent
    /// and FIFO-ordered against any in-flight `start`, so a stop enqueued during
    /// spin-up always tears the engine back down.
    func stop() {
        queue.async { [self] in
            teardownLocked()
        }
    }

    /// Must run on `queue`. A no-op unless this owner is active, so a stop with
    /// nothing running never powers up or reconfigures the mic route.
    private func teardownLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isActive = false
    }
}
