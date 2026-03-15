import AppKit
import SwiftUI

// ┌──────────────────────────────────────────────────────────────────────────┐
// │ Popup Terminal – Window Management Design Notes                         │
// │                                                                         │
// │ The popup is a floating NSPanel toggled via a configurable global       │
// │ hotkey (default: F10), registered through Carbon RegisterEventHotKey.  │
// │ Getting this right on macOS requires careful coordination of three      │
// │ AppKit subsystems that interact in non-obvious ways:                    │
// │                                                                         │
// │ 1. ACTIVATION POLICY (.accessory vs .regular)                          │
// │    • .accessory hides the app from Dock and app switcher.              │
// │    • We switch to .accessory on show so NSApp.activate doesn't raise   │
// │      regular cmux windows (only the popup should appear).              │
// │    • We switch back to .regular on hide so the dock icon works.        │
// │                                                                         │
// │ 2. WINDOW VISIBILITY                                                   │
// │    • On show: we orderOut all visible non-NSPanel windows. This hides  │
// │      terminal windows so only the popup is visible. We do NOT restore  │
// │      them on hide — the user gets them back via the dock icon.         │
// │    • The popup panel uses .transient + .ignoresCycle collection        │
// │      behavior so macOS won't restore it on dock click or Cmd+`.       │
// │                                                                         │
// │ 3. FOCUS RESTORATION                                                   │
// │    • On show: we record which app was frontmost (previousApp).         │
// │    • On hide: if previousApp exists, activate it. If cmux was          │
// │      already focused (previousApp is nil), call NSApp.hide to          │
// │      fully deactivate.                                                 │
// │                                                                         │
// │ Key invariant: F10 always toggles ONLY the popup. Regular windows      │
// │ are hidden as a side effect of show but never restored by hide.        │
// └──────────────────────────────────────────────────────────────────────────┘

/// Singleton controller managing the popup terminal panel.
@MainActor
final class PopupTerminalController: NSObject {

    // MARK: - Singleton

    static let shared = PopupTerminalController()

    // MARK: - Private state

    private var panel: NSPanel?
    private var deactivationObserver: NSObjectProtocol?
    private(set) var isVisible = false
    private var isAnimating = false

    /// The app that was frontmost before the popup was shown.
    /// nil means cmux itself was focused — hide() uses this to decide
    /// whether to activate another app or fully deactivate cmux.
    private var previousApp: NSRunningApplication?

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Public API

    func toggle() {
        if isAnimating { return }
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        isAnimating = true
        let panel = getOrCreatePanel()

        let targetFrame = computeTargetFrame()
        let offscreenFrame = computeOffscreenFrame(for: targetFrame)

        if !isVisible {
            panel.setFrame(offscreenFrame, display: false)
        }

        capturePreviousApp()
        hideRegularWindows(excluding: panel)
        activatePopup(panel)

        isVisible = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PopupTerminalSettings.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.isAnimating = false
                self.installFocusLossObserver()
            }
        })
    }

    /// Hide the popup. When `autoHideTriggered` is true (focus loss), we skip
    /// restoring previousApp because the user already switched to a new app.
    func hide(autoHideTriggered: Bool = false) {
        guard let panel, isVisible else { return }

        isVisible = false
        removeFocusLossObserver()

        let appToRestore = autoHideTriggered ? nil : previousApp
        previousApp = nil

        // Order out immediately — no animation on hide.
        panel.orderOut(nil)

        restoreFocus(to: appToRestore)
    }

    func refreshAutoHideBehavior() {
        guard isVisible else { return }
        if PopupTerminalSettings.autoHideOnFocusLoss {
            installFocusLossObserver()
        } else {
            removeFocusLossObserver()
        }
    }

    func reposition() {
        guard let panel, isVisible else { return }
        let targetFrame = computeTargetFrame()
        panel.setFrame(targetFrame, display: true)
    }

    // MARK: - Show/hide helpers

    /// Record which app was frontmost so we can restore it on hide.
    /// If cmux is already frontmost, leaves previousApp as nil so hide()
    /// knows to fully deactivate instead.
    private func capturePreviousApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }
    }

    /// Hide all regular (non-panel) cmux windows. These stay hidden until
    /// the user clicks the dock icon — hide() intentionally does not
    /// restore them, keeping the popup fully independent.
    private func hideRegularWindows(excluding popup: NSPanel) {
        for window in NSApp.windows where window !== popup {
            if window.isVisible && !(window is NSPanel) {
                window.orderOut(nil)
            }
        }
    }

    /// Switch to accessory policy (hides from menu bar/Dock), then
    /// activate the app and make the popup key. The popup's .floating
    /// level keeps it above everything.
    private func activatePopup(_ panel: NSPanel) {
        NSApp.setActivationPolicy(.accessory)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Restore activation policy to .regular (so dock icon works) and
    /// hand focus back. If another app was focused before, activate it.
    /// If cmux was focused before, fully deactivate via NSApp.hide.
    private func restoreFocus(to appToRestore: NSRunningApplication?) {
        NSApp.setActivationPolicy(.regular)

        if let appToRestore {
            appToRestore.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    // MARK: - Panel lifecycle

    private func getOrCreatePanel() -> NSPanel {
        if let existing = panel {
            return existing
        }

        let windowId = UUID()
        let tabManager = TabManager()
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let notificationStore = TerminalNotificationStore.shared

        guard let appDelegate = AppDelegate.shared else {
            return panel ?? NSPanel()
        }

        let root = ContentView(updateViewModel: appDelegate.updateViewModel, windowId: windowId)
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)

        let targetFrame = computeTargetFrame()

        let newPanel = PopupTerminalPanel(
            contentRect: targetFrame,
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        newPanel.title = ""
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = false
        newPanel.isMovable = false
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        // .transient: macOS won't restore this window on dock click.
        // .ignoresCycle: excluded from Cmd+` window cycling.
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.contentView = NSHostingView(rootView: root)
        newPanel.delegate = self

        appDelegate.applyWindowDecorations(to: newPanel)

        panel = newPanel
        return newPanel
    }

    // MARK: - Frame computation

    private func targetScreen() -> NSScreen {
        switch PopupTerminalSettings.screen {
        case .activeScreen:
            return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens[0]
        case .primaryScreen:
            return NSScreen.main ?? NSScreen.screens[0]
        }
    }

    private func computeTargetFrame() -> NSRect {
        let screen = targetScreen()
        return PopupTerminalSettings.computeTargetFrame(
            position: PopupTerminalSettings.position,
            widthPercent: PopupTerminalSettings.widthPercent,
            heightPercent: PopupTerminalSettings.heightPercent,
            visibleFrame: screen.visibleFrame
        )
    }

    private func computeOffscreenFrame(for targetFrame: NSRect) -> NSRect {
        let screen = targetScreen()
        return PopupTerminalSettings.computeOffscreenFrame(
            for: targetFrame,
            position: PopupTerminalSettings.position,
            screenFrame: screen.frame
        )
    }

    // MARK: - Auto-hide on focus loss

    private func installFocusLossObserver() {
        guard PopupTerminalSettings.autoHideOnFocusLoss else { return }
        removeFocusLossObserver()

        // didResignActiveNotification fires only when the user switches
        // to another app (not on intra-app focus changes).
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.hide(autoHideTriggered: true)
            }
        }
    }

    private func removeFocusLossObserver() {
        if let observer = deactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            deactivationObserver = nil
        }
    }
}

// MARK: - NSWindowDelegate

extension PopupTerminalController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if self.isVisible {
                self.hide()
            }
            self.panel = nil
        }
    }
}

// MARK: - Panel subclass

private class PopupTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
