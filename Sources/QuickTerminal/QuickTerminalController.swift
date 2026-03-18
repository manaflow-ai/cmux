import AppKit
import SwiftUI
import Combine

/// Manages a Quake-style drop-down Quick Terminal that slides in/out from a screen edge.
/// Has its own TabManager so splits, tabs, and other workspace features work independently.
@MainActor
final class QuickTerminalController: NSObject, NSWindowDelegate {

    // MARK: - Configuration

    /// The screen edge from which the Quick Terminal slides in.
    let position: QuickTerminalPosition
    private let animationDuration: TimeInterval = 0.2
    /// Horizontal padding on each side (matches ghostty's quick terminal style).
    private let horizontalPadding: CGFloat = 6

    // MARK: - State

    /// Whether the Quick Terminal is currently shown on screen.
    private(set) var visible: Bool = false
    private var window: QuickTerminalWindow?
    /// The dedicated tab manager for the Quick Terminal's workspace.
    private(set) var tabManager: TabManager?
    private var previousApp: NSRunningApplication?
    private var globalHotKey: QuickTerminalHotKey?

    // MARK: - Init

    /// Create a Quick Terminal controller that slides in from the given screen edge.
    init(position: QuickTerminalPosition = .top) {
        self.position = position
        super.init()
        registerGlobalHotKey()
    }

    /// Register the global hot key so Quick Terminal can be toggled from any application.
    func registerGlobalHotKey() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleQuickTerminal)
        let hotKey = QuickTerminalHotKey { [weak self] in
            self?.toggle()
        }
        if !hotKey.register(shortcut: shortcut) {
#if DEBUG
            dlog("quickTerminal.registerGlobalHotKey failed: shortcut=\(shortcut.key)")
#endif
        }
        globalHotKey = hotKey
    }

    // MARK: - Public

    /// Toggle the Quick Terminal: show it if hidden, hide it if visible.
    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    // MARK: - Animate In

    private func animateIn() {
        guard !visible else { return }

        // Remember the previously focused app so we can restore it on hide.
        if !NSApp.isActive {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = front
            }
        }

        let window = ensureWindow()
        guard let screen = NSScreen.main else { return }

        visible = true

        // Resize: slightly narrower than screen for equal side padding.
        var size = position.defaultSize(on: screen)
        if position == .top || position == .bottom {
            size.width -= horizontalPadding * 2
        }
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)

        // Place off-screen.
        position.setInitial(in: window, on: screen)

        // Bring to front above everything during animation.
        window.level = .popUpMenu
        window.makeKeyAndOrderFront(nil)

        // Activate app so we can receive key events when invoked from another app.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Animate to final position.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            position.setFinal(in: window.animator(), on: screen)
        }, completionHandler: { [weak self] in
            guard let self, self.visible else { return }
            // Drop to floating level so menus/dialogs can appear above.
            window.level = .floating
            self.focusTerminal(in: window)
        })
    }

    // MARK: - Animate Out

    private func animateOut() {
        guard visible, let window else { return }
        visible = false

        guard let screen = window.screen ?? NSScreen.main else {
            window.orderOut(nil)
            return
        }

        // Unfocus surfaces so ghostty doesn't keep rendering.
        if let workspace = tabManager?.selectedWorkspace,
           let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId] {
            panel.unfocus()
        }

        // Restore previously active application.
        if let prev = previousApp, !prev.isTerminated {
            previousApp = nil
            prev.activate(options: [])
        } else {
            previousApp = nil
        }

        window.level = .popUpMenu

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            position.setInitial(in: window.animator(), on: screen)
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    // MARK: - Window / TabManager Setup

    private func ensureWindow() -> QuickTerminalWindow {
        if let window { return window }

        let window = QuickTerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400))
        window.delegate = self
        self.window = window

        // Create a dedicated TabManager for the quick terminal.
        let tm = TabManager()
        tm.window = window
        self.tabManager = tm

        // Create an initial workspace.
        tm.addWorkspace(select: true)

        // Embed via NSHostingView.
        let contentView = QuickTerminalContentView(
            tabManager: tm,
            notificationStore: TerminalNotificationStore.shared
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: window.frame.size)
        hostingView.autoresizingMask = [.width, .height]

        window.initialFrame = window.frame
        window.contentView = hostingView
        window.initialFrame = nil

        return window
    }

    private func focusTerminal(in window: NSWindow, retries: UInt8 = 10) {
        guard visible, let tabManager else { return }

        window.makeKeyAndOrderFront(nil)

        // Focus the terminal surface in the selected workspace.
        if let workspace = tabManager.selectedWorkspace,
           let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId] as? TerminalPanel {
            window.makeFirstResponder(panel.surface.focusableView)
            panel.focus()
        }

        // Retry if the window hasn't become key yet.
        guard !window.isKeyWindow, retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            self?.focusTerminal(in: window, retries: retries - 1)
        }
    }

    // MARK: - NSWindowDelegate

    /// Auto-hide the Quick Terminal when it loses key window status.
    func windowDidResignKey(_ notification: Notification) {
        guard visible else { return }
        guard window?.attachedSheet == nil else { return }
        if NSApp.isActive {
            previousApp = nil
        }
        animateOut()
    }
}
