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
    /// The window was miniaturized and is deminiaturizing from the Dock;
    /// AppKit completes visibility with the unminiaturize animation. Not
    /// `.presented` — the window is not visible yet — and the presenter runs
    /// a bounded follow-up that tears the window down loudly if visibility
    /// never arrives, so a stalled transition cannot become a silent success.
    case deminiaturizing
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
    private var pendingNavigationTarget: SettingsNavigationTarget?
    /// Current re-entrant depth of `performShow` (close-triggered observers
    /// may re-enter). Bounded by `maxReentrantShowDepth`.
    private var activeShowDepth = 0
    /// Monotonic delivery token: bumped on every posted navigation so a
    /// queued fresh-window delivery can detect it was superseded by a newer
    /// targeted show and stay silent instead of navigating backwards.
    private var navigationDeliveryGeneration = 0
    /// Whether the current window's SwiftUI content has signaled (via the
    /// host root's `onAppear`) that its navigation consumer is installed;
    /// posting before then would drop the navigation on the floor.
    private var isContentReadyForNavigation = false
    /// In-flight bounded verification of a `.deminiaturizing` outcome.
    private var deminiaturizeVerificationTask: Task<Void, Never>?

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

            let wasMiniaturized = window.isMiniaturized
            orderFront(window, activateApp: activateApp)

            if window.isVisible {
                deliverNavigation(reusedExistingWindow: reusedExisting)
                return .presented
            }
            if NSApp.isHidden && !activateApp {
                // Ordering front succeeded as far as AppKit allows without
                // unhiding the app; the window appears on unhide. Reused live
                // content still receives the navigation now — its notification
                // subscriptions outlive visibility, and the host root's
                // onAppear consumer only runs for fresh windows. Checked
                // before the deminiaturize branch: under a hidden app the
                // animation cannot produce visibility either.
                deliverNavigation(reusedExistingWindow: reusedExisting)
                Self.log.notice(
                    "settings.window.show ordered front while app is hidden; deferring visibility to unhide"
                )
                return .orderedWhileAppHidden
            }
            if wasMiniaturized && !window.isMiniaturized {
                // Deminiaturizing from the Dock is asynchronous: the window
                // reports `isVisible == false` on this run-loop turn while
                // AppKit animates it in. Preserve the live window (falling
                // through would demolish a healthy, about-to-appear window)
                // but do not claim `.presented`; a bounded follow-up verifies
                // visibility actually arrived.
                deliverNavigation(reusedExistingWindow: reusedExisting)
                beginDeminiaturizeVerification(for: window)
                Self.log.notice(
                    "settings.window.show deminiaturizing from the Dock; visibility follows the animation"
                )
                return .deminiaturizing
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
        return .failed(reason: failureReason)
    }

    func consumePendingNavigationTarget() -> SettingsNavigationTarget? {
        let target = pendingNavigationTarget
        pendingNavigationTarget = nil
        return target
    }

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

    private func orderFront(_ window: NSWindow, activateApp: Bool) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.adoptCmuxPeerWindowLevel()
        clampToVisibleAreaIfNeeded(window)
        guard activateApp else {
            // Socket no-focus-steal contract (`settings.open --activate=false`):
            // make the window visible without keying it, raising other cmux
            // windows, or activating/unhiding the app.
            window.orderFrontRegardless()
            return
        }
        // Surface the preferred main window first so Settings opens layered
        // above it — the standard "Settings in front of its app" presentation.
        // Both windows are ordered front *as peers*, never via
        // `addChildWindow`: a child window is pinned above its parent forever
        // and can never recede when the user clicks the main window
        // (https://github.com/manaflow-ai/cmux/issues/5081).
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

    /// Ready live content receives the navigation immediately. Until the
    /// content signals readiness (a window can exist before its navigation
    /// consumer is installed — fresh creation, hidden app), the target stays
    /// pending and ``SettingsWindowHostRoot`` delivers it from `onAppear` via
    /// `deliverPendingNavigationAfterContentAppears()`.
    private func deliverNavigation(reusedExistingWindow: Bool) {
        guard let target = pendingNavigationTarget else { return }
        if reusedExistingWindow && isContentReadyForNavigation {
            pendingNavigationTarget = nil
            navigationDeliveryGeneration &+= 1
            SettingsNavigationRequest.post(target)
        }
    }

    /// Marks the content ready and delivers any pending target. The post is
    /// deferred one main-actor hop so the content's own restore navigation
    /// (posted from a descendant `onAppear`) cannot clobber it, and it is
    /// generation-guarded: a newer targeted `show()` that delivered in the
    /// meantime supersedes this queued post instead of being overridden by it.
    func deliverPendingNavigationAfterContentAppears() {
        isContentReadyForNavigation = true
        guard let target = pendingNavigationTarget else { return }
        pendingNavigationTarget = nil
        navigationDeliveryGeneration &+= 1
        let generation = navigationDeliveryGeneration
        Task { @MainActor in
            guard self.navigationDeliveryGeneration == generation else { return }
            SettingsNavigationRequest.post(target)
        }
    }

    /// Bounded follow-up for `.deminiaturizing`: the unminiaturize animation
    /// is sub-second, so a window that is still not visible well after it
    /// should have completed — and was not re-miniaturized, and is not under
    /// a hidden app — is a stalled transition. It is torn down loudly so the
    /// next open self-heals with a fresh window instead of reusing the husk.
    private func beginDeminiaturizeVerification(for window: NSWindow) {
        deminiaturizeVerificationTask?.cancel()
        deminiaturizeVerificationTask = Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, let window,
                  window === self.settingsWindow else { return }
            if window.isVisible || window.isMiniaturized || NSApp.isHidden { return }
            Self.log.fault(
                "settings.window.show deminiaturize never became visible; demolishing so the next open self-heals"
            )
            self.demolish(window)
        }
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

    // MARK: - Diagnostics

    private static func logExistingWindowState(_ window: NSWindow) {
        log.notice(
            """
            settings.window.show found existing window \
            visible=\(window.isVisible, privacy: .public) \
            miniaturized=\(window.isMiniaturized, privacy: .public) \
            onActiveSpace=\(window.isOnActiveSpace, privacy: .public) \
            offAllScreens=\(window.screen == nil, privacy: .public) \
            frame=\(NSStringFromRect(window.frame), privacy: .public)
            """
        )
    }

    // `clampToVisibleAreaIfNeeded` and the pure multi-monitor recovery
    // helpers live in Sources/App/SettingsWindowGeometry.swift.
}
