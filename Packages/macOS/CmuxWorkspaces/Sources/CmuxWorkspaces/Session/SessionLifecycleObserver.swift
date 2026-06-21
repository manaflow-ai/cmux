public import Foundation
public import AppKit

/// Owns the three `NSWorkspace` lifecycle observers the app reacts to for
/// session-snapshot persistence and socket recovery, surfacing them as a single
/// typed ``SessionLifecycleEvent`` `AsyncStream` instead of three raw
/// `NotificationCenter` closures.
///
/// Faithful lift of the observer half of
/// `AppDelegate.installLifecycleSnapshotObserversIfNeeded()`: the install-once
/// latch, the registrations against `NSWorkspace.shared.notificationCenter` on
/// the main queue, and the observer-token lifetime. The app's reaction to each
/// event (write a snapshot, flush closed-item history, restart the socket
/// listener) is irreducibly app-coupled — it reads the live window/tab/sidebar
/// tree and writes the snapshot file — so it stays app-side: the app holds this
/// observer, consumes ``events`` on the main actor, and forwards each case to
/// the same bodies the legacy closures called, preserving the
/// `isTerminatingApp` branch exactly.
///
/// **Why an `AsyncStream` replaces the closures.** Each legacy observer fired on
/// the main queue and immediately hopped into `Task { @MainActor in … }`. A
/// `@MainActor` `for await` over this stream arrives on the main actor with the
/// same one-turn-per-event ordering, so the app-side branch runs in an
/// equivalent isolation context. The stream coalesces with
/// `.bufferingNewest(…)` only enough to never drop a distinct event between
/// turns (these notifications are rare); see ``events``.
///
/// **Isolation design.** `@MainActor` because ``installIfNeeded()`` registers on
/// the main queue and the install-once latch is read and written on the main
/// actor exactly as the legacy `didInstallLifecycleSnapshotObservers` guard was.
/// The `AsyncStream` itself is `nonisolated` (it is just a value), built once at
/// `init`; its continuation is retained so ``installIfNeeded()`` can register
/// observers that yield into it. The notification handlers run on the main
/// queue and only call `continuation.yield`, which is `Sendable`.
///
/// **Token lifetime mirrors the legacy.** The legacy appended each observer
/// token to `AppDelegate.lifecycleSnapshotObservers`, which lived for the app's
/// lifetime; the app holds this observer for the app's lifetime, so the tokens
/// live equivalently. ``stop()`` (and stream termination) removes them, which
/// the legacy never did — a strictly-additive teardown path the app does not
/// invoke, so behavior is unchanged.
@MainActor
public final class SessionLifecycleObserver {
    /// The notification center the observers register against. Defaults to
    /// `NSWorkspace.shared.notificationCenter`, the exact center the legacy
    /// observers used; injected so tests can post the same `NSWorkspace` names
    /// to a scoped center.
    private let center: NotificationCenter

    /// The retained continuation the notification handlers yield into.
    private let continuation: AsyncStream<SessionLifecycleEvent>.Continuation

    /// The lifecycle event stream. Yields one ``SessionLifecycleEvent`` per
    /// observed `NSWorkspace` notification, in arrival order on whatever actor
    /// the consumer awaits on. The app awaits it on the main actor and forwards
    /// each case to its session-save / socket-restart body.
    public let events: AsyncStream<SessionLifecycleEvent>

    /// Install-once latch, matching the legacy
    /// `didInstallLifecycleSnapshotObservers` guard so a second
    /// ``installIfNeeded()`` call is a no-op.
    private var didInstall = false

    /// The registered observer tokens, kept so ``stop()`` / stream termination
    /// can remove them. Equivalent to the legacy
    /// `AppDelegate.lifecycleSnapshotObservers` array.
    private var tokens: [NSObjectProtocol] = []

    /// Creates an observer.
    ///
    /// - Parameter center: the notification center to observe (default
    ///   `NSWorkspace.shared.notificationCenter`, the legacy center).
    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
        (events, continuation) = AsyncStream<SessionLifecycleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
    }

    /// Registers the three `NSWorkspace` lifecycle observers once. Idempotent,
    /// matching the legacy install-once guard. The observers yield the matching
    /// ``SessionLifecycleEvent`` into ``events``.
    public func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true

        let continuation = continuation
        tokens.append(
            center.addObserver(
                forName: NSWorkspace.willPowerOffNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.willPowerOff)
            }
        )
        tokens.append(
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.sessionDidResignActive)
            }
        )
        tokens.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(.didWake)
            }
        )
    }

    /// Removes the observers and finishes the stream. The app does not call this
    /// (the legacy never removed its observers); it exists so the observer is a
    /// complete, leak-free owner of its registrations.
    public func stop() {
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
        continuation.finish()
    }
}
