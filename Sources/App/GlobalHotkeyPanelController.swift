import AppKit
import SwiftUI

@MainActor
enum GlobalHotkeyPanelLayout {
    static func panelFrame(in screenFrame: NSRect) -> NSRect {
        let margin = max(20, min(56, screenFrame.height * 0.045))
        let width = min(max(960, screenFrame.width * 0.88), screenFrame.width - (margin * 2))
        let height = min(max(560, screenFrame.height * 0.78), screenFrame.height - (margin * 2))
        let origin = NSPoint(
            x: screenFrame.midX - (width / 2),
            y: screenFrame.maxY - height - margin
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height)).integral
    }

    static func preferredScreen(for point: NSPoint = NSEvent.mouseLocation) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

@MainActor
enum GlobalHotkeyPanelConfiguration {
    static let styleMask: NSWindow.StyleMask = [
        .nonactivatingPanel,
        .titled,
        .resizable,
        .fullSizeContentView,
    ]

    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .transient,
        .ignoresCycle,
    ]

    static var windowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 2)
    }

    static func apply(to panel: NSPanel) {
        panel.level = windowLevel
        panel.collectionBehavior = collectionBehavior
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .utilityWindow
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.isRestorable = false
        panel.isReleasedWhenClosed = false
    }
}

@MainActor
final class GlobalHotkeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if ShortcutStroke.isEscapeCancelEvent(event) {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class GlobalHotkeyPanelController: NSObject, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private var windowController: NSWindowController?
    private var windowId: UUID?
    private var tabManager: TabManager?
    private var sidebarState: SidebarState?
    private var sidebarSelectionState: SidebarSelectionState?
    private var fileExplorerState: FileExplorerState?
    private var cmuxConfigStore: CmuxConfigStore?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
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

        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        appDelegate?.setActiveMainWindow(panel)

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

        let windowId = UUID()
        let tabManager = TabManager(autoWelcomeIfNeeded: true)
        let notificationStore = TerminalNotificationStore.shared
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let fileExplorerState = FileExplorerState()
        let cmuxConfigStore = CmuxConfigStore()
        cmuxConfigStore.wireDirectoryTracking(tabManager: tabManager)
        cmuxConfigStore.loadAll()

        let root = ContentView(updateViewModel: appDelegate.updateViewModel, windowId: windowId)
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)
            .environmentObject(fileExplorerState)
            .environmentObject(cmuxConfigStore)

        let initialFrame = GlobalHotkeyPanelLayout.preferredScreen()
            .map { GlobalHotkeyPanelLayout.panelFrame(in: $0.frame) }
            ?? NSRect(x: 120, y: 120, width: 1_000, height: 700)
        let panel = GlobalHotkeyPanel(
            contentRect: initialFrame,
            styleMask: GlobalHotkeyPanelConfiguration.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.hotkeyPanel")
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
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore,
            role: .globalHotkeyPanel
        )
        appDelegate.publishCmuxWindowLifecycle(name: "window.created", windowId: windowId, origin: "global_hotkey")
        installFileDropOverlay(on: panel, tabManager: tabManager)

        self.windowId = windowId
        self.tabManager = tabManager
        self.sidebarState = sidebarState
        self.sidebarSelectionState = sidebarSelectionState
        self.fileExplorerState = fileExplorerState
        self.cmuxConfigStore = cmuxConfigStore
        windowController = NSWindowController(window: panel)
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = GlobalHotkeyPanelLayout.preferredScreen() else { return }
        panel.setFrame(GlobalHotkeyPanelLayout.panelFrame(in: screen.frame), display: false)
    }
}
