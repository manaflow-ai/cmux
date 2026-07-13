import AppKit
import CmuxTestSupport
import os

/// Outcome of a Settings show request. Every request ends in exactly one of
/// these; "the request was accepted but nothing happened" is not
/// representable (https://github.com/manaflow-ai/cmux/issues/7777, #7775).
enum SettingsWindowShowResult: Equatable {
    /// The Settings window is visible on screen (ordered in).
    case presented
    /// The window was ordered front while the app is hidden, so AppKit defers
    /// actual visibility until the app unhides. This is the correct outcome
    /// for non-activating CLI opens, which must not unhide the app
    /// (socket focus policy).
    case orderedWhileAppHidden
    /// No window could be made visible. `reason` carries diagnostic-grade
    /// window/app state for the failure log and the CLI error payload.
    case failed(reason: String)
}

/// Single source of truth for the Settings window lifecycle: create, show,
/// repair, and close-teardown (https://github.com/manaflow-ai/cmux/issues/7777).
///
/// The window is AppKit-owned: `show()` synchronously builds a fresh
/// `NSWindow` (hosting the SwiftUI settings content via
/// ``SettingsWindowFactory``) whenever no usable window exists, orders it
/// front, and verifies visibility before returning. This is the same
/// ownership model the main window (`AppDelegate.createMainWindow`) and
/// `TaskManagerWindowController` use.
///
/// History: the previous design delegated creation to a SwiftUI single
/// `Window` scene via `openWindow(id:)`, which has no failure callback and
/// could wedge permanently (relaunch-while-open, scene mid-teardown), so the
/// menu, ⌘, and CLI `settings open` all silently no-oped until the app was
/// restarted (#5770, #4053, #7775). A deferred-verification retry (PR #5806)
/// reduced but could not eliminate the class; synchronous AppKit construction
/// removes it by design.
@MainActor
final class SettingsWindowPresenter: NSObject {
    static let windowIdentifier = "cmux.settings"
    static let minimumSize = NSSize(width: 820, height: 540)
    private static let frameAutosaveName = "cmux.settings"
    /// One reuse-or-create pass plus one recreate-from-scratch pass. Creation
    /// is synchronous, so more attempts cannot help: if two consecutive fresh
    /// windows refuse to order in, AppKit itself is wedged and we fail loudly.
    static let maxPresentAttempts = 2
    /// Maximum re-entrant `show()` depth reached through close-triggered
    /// observers before the presenter fails loudly instead of recursing.
    static let maxReentrantShowDepth = 3
    /// How long a show may pump the run loop waiting for an initiated
    /// deminiaturization to land before falling back to window replacement.
    /// Overridable so tests exercising the stalled path stay fast.
    static var deminiaturizeSettleTimeout: TimeInterval = 1.0

    static let shared = SettingsWindowPresenter()
    /// Release-safe diagnostics so intermittent "Settings won't open" reports
    /// become attributable from
    /// `log show --predicate 'subsystem == "com.cmuxterm.app" && category == "Settings"'`.
    /// Internal (not private) so the geometry/recovery extension file logs
    /// through the same channel.
    nonisolated static let log = Logger(subsystem: "com.cmuxterm.app", category: "Settings")

    private let windowFactory: @MainActor (SettingsWindowPresenter) -> NSWindow
    /// Strong while open: the presenter owns the window's lifetime. Cleared
    /// (and the window's identifier removed) in `settingsWindowWillClose` so
    /// a closed window can never absorb a future open request.
    private var settingsWindow: NSWindow?
    // Navigation-delivery state is internal (not private) because its
    // behavior lives in SettingsWindowNavigationDelivery.swift (split for
    // the file-length budget); no type outside the presenter touches it.
    var pendingNavigationTarget: SettingsNavigationTarget?
    /// Current re-entrant depth of `performShow` (close-triggered observers
    /// may re-enter). Bounded by `maxReentrantShowDepth`.
    private var activeShowDepth = 0
    /// Window whose deminiaturization an outer `performShow` is currently
    /// awaiting. `deminiaturize` clears `isMiniaturized` before visibility
    /// lands, so without this a re-entrant show during the wait would see a
    /// plain invisible window and demolish the live transition.
    private var windowAwaitingDeminiaturize: NSWindow?
    /// Monotonic delivery token: bumped on every posted navigation so a
    /// queued fresh-window delivery can detect it was superseded by a newer
    /// targeted show and stay silent instead of navigating backwards.
    var navigationDeliveryGeneration = 0
    /// Whether the current window's SwiftUI content has signaled (via the
    /// host root's `onAppear`) that its navigation consumer is installed;
    /// posting before then would drop the navigation on the floor.
    var isContentReadyForNavigation = false

    override convenience init() {
        // Content readiness reports back to the presenter instance that owns
        // the window (never the singleton), so instance presenters — e.g.
        // the real-factory regression tests — drain their own navigation.
        self.init(windowFactory: { presenter in
            SettingsWindowFactory.makeSettingsWindow(onContentAppear: { [weak presenter] in
                presenter?.deliverPendingNavigationAfterContentAppears()
            })
        })
    }

    init(windowFactory: @escaping @MainActor (SettingsWindowPresenter) -> NSWindow) {
        self.windowFactory = windowFactory
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @discardableResult
    static func show(
        navigationTarget: SettingsNavigationTarget? = nil,
        activateApp: Bool = true
    ) -> SettingsWindowShowResult {
        shared.show(navigationTarget: navigationTarget, activateApp: activateApp)
    }

    /// Presents the Settings window, creating it if needed. Synchronous: on
    /// return the window is visible (or ordered front under a hidden app), or
    /// the failure has been logged loudly and is carried in the result.
    @discardableResult
    func show(
        navigationTarget: SettingsNavigationTarget? = nil,
        activateApp: Bool = true
    ) -> SettingsWindowShowResult {
#if DEBUG
        cmuxDebugLog("settings.window.show path=appkitWindow")
#endif
        let result = performShow(navigationTarget: navigationTarget, activateApp: activateApp)
#if DEBUG
        // Recorded from the verified outcome, not the request, so UI-test
        // captures cannot claim an open that never presented.
        let presented: Bool
        if case .failed = result {
            presented = false
        } else {
            presented = true
        }
        _ = UITestCaptureSink().mutateJSONObjectIfConfigured(
            envKey: "CMUX_UI_TEST_SETTINGS_OPEN_CAPTURE_PATH"
        ) { payload in
            payload["opened"] = presented
            payload["target"] = navigationTarget?.rawValue ?? ""
        }
#endif
        return result
    }

    private func performShow(
        navigationTarget: SettingsNavigationTarget?,
        activateApp: Bool
    ) -> SettingsWindowShowResult {
        // Only a targeted show may replace the pending target. An untargeted
        // show expresses no pane preference and must not erase a still-
        // undelivered targeted request (e.g. CLI `settings open account`
        // followed by a menu open before the content appeared).
        if let navigationTarget {
            pendingNavigationTarget = navigationTarget
        }

        // `demolish` closes windows synchronously, and a foreign willClose
        // observer may re-enter show() from inside that close (a supported
        // pattern). The depth bound is the safety valve that keeps a
        // pathological reopen-on-close observer combined with persistent
        // presentation failure from recursing without limit.
        activeShowDepth += 1
        defer { activeShowDepth -= 1 }
        if activeShowDepth > Self.maxReentrantShowDepth {
            let reason = "re-entrant settings show exceeded depth \(Self.maxReentrantShowDepth) during teardown recovery"
            Self.log.fault("settings.window.show \(reason, privacy: .public)")
            return .failed(reason: reason)
        }

        var failureReason = "settings window was never presented"
        var didUnhideForVerification = false
        for attempt in 1...Self.maxPresentAttempts {
            let window: NSWindow
            let reusedExisting: Bool
            // Checked on every attempt, not just the first: attempt 1's
            // demolish strips the failed window before closing it, so it can
            // never be rediscovered here — but a re-entrant show() from that
            // close may already have created a healthy replacement, which
            // must be adopted instead of duplicated.
            if let existing = usableExistingWindow() {
                Self.logExistingWindowState(existing)
                adopt(existing)
                window = existing
                reusedExisting = true
            } else {
                window = makeConfiguredWindow()
                reusedExisting = false
            }

            // A re-entrant show during an in-flight deminiaturization must
            // coalesce onto the transition, not treat the (no longer
            // miniaturized, not yet visible) window as a failed husk.
            let wasMiniaturized = window.isMiniaturized || windowAwaitingDeminiaturize === window
            orderFrontWithoutActivation(window)
            if activateApp && !window.isVisible && NSApp.isHidden {
                // The app being hidden can be exactly what visibility is
                // waiting on. Unhide WITHOUT activating (the API exists for
                // precisely this) so verification itself never activates the
                // app or redirects focus; the failure exit re-hides.
                NSApp.unhideWithoutActivation()
                didUnhideForVerification = true
            }
            if NSApp.isHidden && !activateApp {
                // Ordering front succeeded as far as AppKit allows without
                // unhiding the app; the window appears on unhide. Checked
                // before the deminiaturize wait: under a hidden app no
                // amount of waiting produces visibility, and this is the
                // synchronous socket path (`settings.open --activate=false`)
                // that must not stall. Reused live content still receives
                // the navigation now — its subscriptions outlive visibility.
                deliverNavigation(reusedExistingWindow: reusedExisting)
                Self.log.notice(
                    "settings.window.show ordered front while app is hidden; deferring visibility to unhide"
                )
                return .orderedWhileAppHidden
            }
            if wasMiniaturized && !window.isVisible {
                // The deminiaturization was initiated above; give AppKit a
                // bounded chance to land it before concluding failure, so a
                // live window full of unsaved edits is never destroyed just
                // because an OS version commits the transition a turn later.
                let previousAwaiting = windowAwaitingDeminiaturize
                windowAwaitingDeminiaturize = window
                defer { windowAwaitingDeminiaturize = previousAwaiting }
                awaitVisibility(of: window, timeout: Self.deminiaturizeSettleTimeout)
                if settingsWindow !== window {
                    // The nested pump processed a close or a re-entrant
                    // show; this attempt's window is gone. Report reality —
                    // never resurrect a window the user just closed — and an
                    // adopted replacement still owes this request its
                    // activation semantics (the re-entrant show may have
                    // presented without activating).
                    if let current = settingsWindow, current.isVisible {
                        if activateApp {
                            activateAndSurface(current)
                        }
                        deliverNavigation(reusedExistingWindow: true)
                        return .presented
                    }
                    failureReason = "settings window was closed while deminiaturizing"
                    Self.log.notice("settings.window.show \(failureReason, privacy: .public)")
                    break
                }
            }

            if window.isVisible {
                // Activation (unhide, activate, make key) runs only after
                // visibility is verified, so a failed presentation can never
                // activate the app or steal focus as a side effect.
                if activateApp {
                    activateAndSurface(window)
                }
                deliverNavigation(reusedExistingWindow: reusedExisting)
                return .presented
            }

            failureReason = Self.presentationFailureReason(
                window: window,
                attempt: attempt,
                reusedExisting: reusedExisting
            )
            Self.log.error("settings.window.show \(failureReason, privacy: .public)")
            demolish(window)
        }

        Self.log.fault(
            "settings.window.show FAILED after \(Self.maxPresentAttempts, privacy: .public) attempts: \(failureReason, privacy: .public)"
        )
        // A failed request must not leak its target into a later open: an
        // untargeted show deliberately preserves pending targets, so without
        // this a later recovered open would navigate to a pane whose request
        // already received `.failed`. Only this request's own target is
        // cleared — a re-entrant show that set a different target supersedes.
        if pendingNavigationTarget == navigationTarget {
            pendingNavigationTarget = nil
        }
        if didUnhideForVerification {
            // The (non-activating) unhide above was a verification gamble
            // that did not pay off; re-hide so a failed presentation leaves
            // the app exactly as the caller found it. Focus was never
            // touched: activation only ever runs after verified visibility.
            NSApp.hide(nil)
        }
        return .failed(reason: failureReason)
    }

    // Navigation delivery lives in SettingsWindowNavigationDelivery.swift.

    // MARK: - Window acquisition

    /// The tracked (or identifier-scanned) settings window, provided it is in
    /// a presentable state. Any unusable window — torn-down content, a
    /// degenerate frame — is demolished on the spot so the caller creates a
    /// fresh one instead of silently re-fronting a husk (issue #7777 goal:
    /// self-healing open).
    private func usableExistingWindow() -> NSWindow? {
        let candidate = settingsWindow ?? NSApp.windows.first {
            $0.identifier?.rawValue == Self.windowIdentifier
        }
        guard let candidate else { return nil }
        if let hostWindow = candidate as? SettingsHostWindow, hostWindow.isClosingSettingsWindow {
            // Deterministic mid-close rejection: the dying window must not
            // absorb this open request, regardless of whether the presenter's
            // own willClose observer has run yet. It is already closing, so
            // strip identity but do not close it again.
            Self.log.notice("settings.window.show candidate is mid-close; building a fresh window")
            strip(candidate)
            return nil
        }
        if let reason = Self.unusableWindowReason(
            hasContent: candidate.contentViewController != nil || candidate.contentView != nil,
            frame: candidate.frame,
            minimumSize: Self.minimumSize
        ) {
            Self.log.error(
                "settings.window.show existing window unusable (\(reason, privacy: .public)); tearing it down"
            )
            demolish(candidate)
            return nil
        }
        return candidate
    }

    /// Tracks a window discovered by identifier scan (e.g. after presenter
    /// state was lost) so close-teardown ownership is re-established.
    private func adopt(_ window: NSWindow) {
        guard settingsWindow !== window else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        settingsWindow = window
    }

    private func makeConfiguredWindow() -> NSWindow {
        let window = windowFactory(self)
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = Self.minimumSize
        window.contentMinSize = Self.minimumSize
        window.adoptCmuxPeerWindowLevel()
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        // A saved frame can be smaller than the current minimum (e.g. written
        // by an older build); NSWindow.minSize constrains user resizes only,
        // not programmatic restores.
        var frame = window.frame
        if frame.width < Self.minimumSize.width || frame.height < Self.minimumSize.height {
            frame.size.width = max(frame.width, Self.minimumSize.width)
            frame.size.height = max(frame.height, Self.minimumSize.height)
            window.setFrame(frame, display: false)
        }
        clampToVisibleAreaIfNeeded(window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        settingsWindow = window
        isContentReadyForNavigation = false
        return window
    }

    // MARK: - Presentation

    /// Orders the window in without touching app activation, unhide, or key
    /// status, so visibility can be verified before any focus-affecting side
    /// effect. This alone satisfies the socket no-focus-steal contract
    /// (`settings.open --activate=false`).
    private func orderFrontWithoutActivation(_ window: NSWindow) {
        if window.isMiniaturized {
            // Reusing (not replacing) a Dock-miniaturized window preserves
            // its SwiftUI tree and any unsaved Settings edits; the caller
            // waits out the transition via `awaitVisibility(of:timeout:)`.
            window.deminiaturize(nil)
        }
        window.adoptCmuxPeerWindowLevel()
        clampToVisibleAreaIfNeeded(window)
        window.orderFrontRegardless()
    }

    /// Bounded synchronous wait for an initiated deminiaturization: pumps
    /// the main run loop in small slices (as AppKit's own modal and menu
    /// tracking do) until the window reports visible, ownership changes
    /// (the pump processed a close or re-entrant show — caller re-examines),
    /// or the deadline passes. Instant where `deminiaturize` +
    /// `orderFrontRegardless` commits same-turn (probed on macOS 26);
    /// elsewhere it lets AppKit finish instead of tearing down a live window
    /// full of unsaved edits. Deadline expiry means genuinely wedged.
    private func awaitVisibility(of window: NSWindow, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !window.isVisible && settingsWindow === window && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// The focus-affecting half of presentation, run only for `activateApp`
    /// requests and only once the window is visible (or when unhiding the
    /// app is itself what visibility is waiting on). Surfaces the preferred
    /// main window first so Settings opens layered above it — both windows
    /// ordered front *as peers*, never via `addChildWindow`: a child window
    /// is pinned above its parent forever and can never recede when the user
    /// clicks the main window
    /// (https://github.com/manaflow-ai/cmux/issues/5081).
    private func activateAndSurface(_ window: NSWindow) {
        if let parentWindow = AppDelegate.shared?.preferredMainWindowForSettingsPresentation(),
           parentWindow !== window {
            if parentWindow.isMiniaturized {
                parentWindow.deminiaturize(nil)
            }
            parentWindow.orderFront(nil)
        }
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Teardown

    /// Fully retires a window that must never satisfy an open request again.
    private func demolish(_ window: NSWindow) {
        strip(window)
        window.orderOut(nil)
        window.close()
        window.contentViewController = nil
        window.contentView = nil
    }

    /// Removes the window's settings identity and the presenter's tracking,
    /// without closing it (used for windows that are already mid-close).
    private func strip(_ window: NSWindow) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: window
        )
        window.identifier = nil
        if settingsWindow === window {
            settingsWindow = nil
            isContentReadyForNavigation = false
        }
    }

    @objc
    private func settingsWindowWillClose(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            window === settingsWindow
        else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: window
        )
        // A closed window must never be rediscovered by an open request, and
        // its SwiftUI tree must be released with it so it cannot linger
        // half-alive (the #4964 blank-reopen / #5321 lingering-window
        // classes). The next show() builds a fresh window from scratch.
        window.identifier = nil
        settingsWindow = nil
        isContentReadyForNavigation = false
        window.contentViewController = nil
        window.contentView = nil
    }

    // Multi-monitor recovery + diagnostics live in SettingsWindowGeometry.swift.
}
