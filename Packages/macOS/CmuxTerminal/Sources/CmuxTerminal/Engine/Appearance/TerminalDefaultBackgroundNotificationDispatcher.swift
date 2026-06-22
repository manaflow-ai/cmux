public import AppKit
internal import Foundation
internal import CmuxFoundation

/// Coalesces Ghostty appearance/background-change notifications so chrome
/// consumers only observe the latest runtime terminal colors for a burst of
/// updates.
///
/// This is the cold appearance/background notify path drained out of the
/// `GhosttyApp` god type in `GhosttyTerminalView.swift`. It runs only when the
/// terminal's resolved default background changes (config reload, OS appearance
/// change, OSC color-change), never per render frame, so it carries no
/// latency-critical work. The engine resolves the new colors on the main thread
/// and calls ``signal(backgroundColor:opacity:eventId:source:foregroundColor:cursorColor:cursorTextColor:selectionBackground:selectionForeground:)``;
/// the dispatcher records the latest payload and posts a single
/// ``Foundation/Notification/Name/ghosttyDefaultBackgroundDidChange`` after the
/// coalescing delay, dropping intermediate updates in the same burst.
///
/// The posted `userInfo` keys are
/// ``TerminalDefaultBackgroundUserInfoKey`` whose raw string values match the
/// app target's `GhosttyNotificationKey` constants byte-for-byte, so existing
/// app-side observers keep wire compatibility.
///
/// Isolation design: the legacy `GhosttyDefaultBackgroundNotificationDispatcher`
/// was a non-isolated class whose mutable state was touched only from the main
/// thread (`signal` marshalled to main via `Thread.isMainThread` /
/// `DispatchQueue.main.async`, and the owned coalescer preconditioned
/// main-thread use). This drain preserves that exact non-isolated shape so the
/// app-target `GhosttyApp` (itself a non-isolated class) keeps constructing and
/// calling it byte-identically with no `@MainActor` ripple. All mutable state
/// is touched only on the main thread by the same `Thread.isMainThread` hop the
/// legacy code used; the owned ``AppearanceNotificationCoalescer`` carries the
/// one `@unchecked Sendable` escape hatch the package's strict concurrency
/// requires for its `DispatchQueue.main.asyncAfter` self-capture, justified
/// there as main-thread-confined state.
public final class TerminalDefaultBackgroundNotificationDispatcher {
    private let coalescer: AppearanceNotificationCoalescer
    private let postNotification: ([AnyHashable: Any]) -> Void
    private var pendingUserInfo: [AnyHashable: Any]?
    private var pendingEventId: UInt64 = 0
    private var pendingSource: String = "unspecified"
    private let logEvent: ((String) -> Void)?

    /// Creates a dispatcher that coalesces a burst of background changes into a
    /// single notification flushed `delay` seconds after the first signal.
    ///
    /// - Parameters:
    ///   - delay: The coalescing window. A delay of `0` flushes on the next main
    ///     run-loop turn, matching the engine's same-frame chrome-tracking
    ///     configuration. Defaults to one 30 Hz frame.
    ///   - logEvent: Optional DEBUG diagnostic sink for the engine's background
    ///     log; receives the queued/flushed/posted trace lines.
    ///   - postNotification: The posting side effect, injected for testability;
    ///     defaults to posting
    ///     ``Foundation/Notification/Name/ghosttyDefaultBackgroundDidChange`` on
    ///     `NotificationCenter.default`.
    public init(
        delay: TimeInterval = 1.0 / 30.0,
        logEvent: ((String) -> Void)? = nil,
        postNotification: @escaping ([AnyHashable: Any]) -> Void = { userInfo in
            NotificationCenter.default.post(
                name: .ghosttyDefaultBackgroundDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
    ) {
        coalescer = AppearanceNotificationCoalescer(delay: delay)
        self.logEvent = logEvent
        self.postNotification = postNotification
    }

    /// Records the latest resolved terminal appearance colors and schedules a
    /// coalesced ``Foundation/Notification/Name/ghosttyDefaultBackgroundDidChange``
    /// post.
    ///
    /// Off-main callers are hopped to main before the pending payload is
    /// recorded, matching the legacy dispatcher's `Thread.isMainThread` guard.
    public func signal(
        backgroundColor: NSColor,
        opacity: Double,
        eventId: UInt64,
        source: String,
        foregroundColor: NSColor,
        cursorColor: NSColor,
        cursorTextColor: NSColor,
        selectionBackground: NSColor,
        selectionForeground: NSColor
    ) {
        let signalOnMain = { [self] in
            pendingEventId = eventId
            pendingSource = source
            pendingUserInfo = [
                TerminalDefaultBackgroundUserInfoKey.backgroundColor: backgroundColor,
                TerminalDefaultBackgroundUserInfoKey.backgroundOpacity: opacity,
                TerminalDefaultBackgroundUserInfoKey.backgroundEventId: NSNumber(value: eventId),
                TerminalDefaultBackgroundUserInfoKey.backgroundSource: source,
                TerminalDefaultBackgroundUserInfoKey.foregroundColor: foregroundColor,
                TerminalDefaultBackgroundUserInfoKey.cursorColor: cursorColor,
                TerminalDefaultBackgroundUserInfoKey.cursorTextColor: cursorTextColor,
                TerminalDefaultBackgroundUserInfoKey.selectionBackground: selectionBackground,
                TerminalDefaultBackgroundUserInfoKey.selectionForeground: selectionForeground,
            ]
            logEvent?(
                "bg notify queued id=\(eventId) source=\(source) color=\(backgroundColor.hexString()) fg=\(foregroundColor.hexString()) opacity=\(String(format: "%.3f", opacity))"
            )
            coalescer.signal { [self] in
                guard let userInfo = pendingUserInfo else { return }
                let eventId = pendingEventId
                let source = pendingSource
                pendingUserInfo = nil
                logEvent?("bg notify flushed id=\(eventId) source=\(source)")
                logEvent?("bg notify posting id=\(eventId) source=\(source)")
                postNotification(userInfo)
                logEvent?("bg notify posted id=\(eventId) source=\(source)")
            }
        }

        if Thread.isMainThread {
            signalOnMain()
        } else {
            DispatchQueue.main.async(execute: signalOnMain)
        }
    }
}

/// Coalesces repeated main-thread signals into one callback after a short delay,
/// for the appearance notify burst.
///
/// A byte-identical copy of the app-target `NotificationBurstCoalescer` shape
/// the legacy dispatcher owned (the same `1.0 / 30.0` default delay clamped at
/// zero, the same single-pending-action coalescing, the same re-arm when a
/// flush enqueues another action, the same `DispatchQueue.main.asyncAfter`
/// timer). It is package-private to ``TerminalDefaultBackgroundNotificationDispatcher``:
/// the broadly-shared `NotificationBurstCoalescer` lives in the higher
/// `CmuxWorkspaces` package (and as a non-isolated app-target copy), neither of
/// which `CmuxTerminal` may import downward, so the dispatcher owns its own
/// flush timing the same way `CmuxWorkspaces`'s title scheduler does. The legacy
/// coalescer preconditioned main-thread use on every method.
///
/// `@unchecked Sendable` justification: every method is reached only on the main
/// thread (the owning dispatcher hops to main before calling `signal`, and the
/// `DispatchQueue.main.asyncAfter` flush runs on main), so the `isFlushScheduled`
/// and `pendingAction` state is single-thread-confined exactly as the legacy
/// app-target `NotificationBurstCoalescer` was. The conformance only lets the
/// weak `self` capture cross into the main-isolated timer closure under the
/// package's strict Swift 6 mode; it adds no new sharing the legacy code lacked.
private final class AppearanceNotificationCoalescer: @unchecked Sendable {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "AppearanceNotificationCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "AppearanceNotificationCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}
