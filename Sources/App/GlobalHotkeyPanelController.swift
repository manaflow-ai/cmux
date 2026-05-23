import AppKit
import SwiftUI

@MainActor
final class GlobalHotkeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class GlobalHotkeyPanelController: NSObject, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private let contentState: GlobalHotkeyPanelContentState
    private var windowController: NSWindowController?

    init(appDelegate: AppDelegate, contentState: GlobalHotkeyPanelContentState) {
        self.appDelegate = appDelegate
        self.contentState = contentState
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let panel = ensurePanel() else {
            NSSound.beep()
            return
        }

        if NSApp.isHidden {
            NSApp.unhide(nil)
        }
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        appDelegate?.setActiveMainWindow(panel)
        contentState.scheduleConfigLoadAfterFirstDisplay()

#if DEBUG
        cmuxDebugLog("globalHotkey.panel.show window=\(panel.identifier?.rawValue ?? "<nil>")")
#endif
    }

    func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
#if DEBUG
        cmuxDebugLog("globalHotkey.panel.hide window=\(panel.identifier?.rawValue ?? "<nil>")")
#endif
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private var panel: GlobalHotkeyPanel? {
        windowController?.window as? GlobalHotkeyPanel
    }

    private func ensurePanel() -> GlobalHotkeyPanel? {
        if let panel {
            return panel
        }

        guard let appDelegate else { return nil }

        let root = ContentView(updateViewModel: appDelegate.updateViewModel, windowId: contentState.windowId)
            .mainWindowContextRole(.globalHotkeyPanel)
            .environmentObject(contentState.tabManager)
            .environmentObject(contentState.notificationStore)
            .environmentObject(contentState.sidebarState)
            .environmentObject(contentState.sidebarSelectionState)
            .environmentObject(contentState.fileExplorerState)
            .environmentObject(contentState.cmuxConfigStore)

        let initialFrame = GlobalHotkeyPanelLayout.preferredScreen()
            .map { GlobalHotkeyPanelLayout.panelFrame(in: $0.frame) }
            ?? NSRect(x: 120, y: 120, width: 1_000, height: 700)
        let panel = GlobalHotkeyPanel(
            contentRect: initialFrame,
            styleMask: GlobalHotkeyPanelConfiguration.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(GlobalHotkeyPanelConfiguration.windowIdentifier)
        panel.title = String(localized: "globalHotkey.window.title", defaultValue: "cmux Hotkey Window")
        panel.contentView = MainWindowHostingView(rootView: root)
        panel.delegate = self
        panel.onCancel = { [weak self] in
            self?.hide()
        }
        GlobalHotkeyPanelConfiguration.apply(to: panel)

        appDelegate.attachUpdateAccessory(to: panel)
        appDelegate.applyWindowDecorations(to: panel)
        appDelegate.registerMainWindow(
            panel,
            windowId: contentState.windowId,
            tabManager: contentState.tabManager,
            sidebarState: contentState.sidebarState,
            sidebarSelectionState: contentState.sidebarSelectionState,
            fileExplorerState: contentState.fileExplorerState,
            cmuxConfigStore: contentState.cmuxConfigStore,
            role: .globalHotkeyPanel
        )
        appDelegate.publishCmuxWindowLifecycle(name: "window.created", windowId: contentState.windowId, origin: "global_hotkey")
        installFileDropOverlay(on: panel, tabManager: contentState.tabManager)

        windowController = NSWindowController(window: panel)
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = GlobalHotkeyPanelLayout.preferredScreen() else { return }
        panel.setFrame(GlobalHotkeyPanelLayout.panelFrame(in: screen.frame), display: false)
    }
}
