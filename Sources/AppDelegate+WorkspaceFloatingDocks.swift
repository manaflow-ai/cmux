import AppKit
import CmuxFoundation

struct WorkspaceFloatingDockCreationRequest {
    var title: String?
    var initialContent: DockSurfaceKind
    var initialURL: URL?
    var frame: CGRect?
    var backgroundTintHex: String?
    var focus: Bool
    var relativeToDockId: UUID?

    init(
        title: String? = nil,
        initialContent: DockSurfaceKind = .terminal,
        initialURL: URL? = nil,
        frame: CGRect? = nil,
        backgroundTintHex: String? = nil,
        focus: Bool,
        relativeToDockId: UUID? = nil
    ) {
        self.title = title
        self.initialContent = initialContent
        self.initialURL = initialURL
        self.frame = frame
        self.backgroundTintHex = backgroundTintHex
        self.focus = focus
        self.relativeToDockId = relativeToDockId
    }
}

extension AppDelegate.MainWindowContext {
    func installWorkspaceFloatingDockPresenterIfNeeded() {
        guard let window else { return }
        if let workspaceFloatingDockPresenter,
           workspaceFloatingDockPresenter.isAttached(to: window) {
            return
        }
        workspaceFloatingDockPresenter?.teardown()
        workspaceFloatingDockPresenter = WorkspaceFloatingDockPresenter(
            parentWindow: window,
            tabManager: tabManager
        )
    }

    func teardownWorkspaceFloatingDockPresenter() {
        workspaceFloatingDockPresenter?.teardown()
        workspaceFloatingDockPresenter = nil
    }
}

extension AppDelegate {
    func contextForShortcutSourceWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window else { return nil }
        if let context = contextForMainTerminalWindow(window) {
            return context
        }
        return mainWindowContexts.values.first { context in
            context.workspaceFloatingDockPresenter?.owns(window: window) == true
        }
    }

    @discardableResult
    func createWorkspaceFloatingDock(
        in tabManager: TabManager,
        title: String? = nil,
        focus: Bool
    ) -> WorkspaceFloatingDock? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return createWorkspaceFloatingDock(
            in: workspace,
            tabManager: tabManager,
            request: WorkspaceFloatingDockCreationRequest(title: title, focus: focus)
        )
    }

    @discardableResult
    func createWorkspaceFloatingDock(
        in workspace: Workspace,
        tabManager: TabManager,
        request: WorkspaceFloatingDockCreationRequest
    ) -> WorkspaceFloatingDock? {
        guard let dock = workspace.createFloatingDock(
            title: request.title,
            frame: request.frame,
            initialContent: request.initialContent,
            initialURL: request.initialURL,
            backgroundTintHex: request.backgroundTintHex
        ) else { return nil }
        if request.focus, tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        refreshWorkspaceFloatingDocks(
            for: tabManager,
            focusDockId: request.focus ? dock.id : nil,
            placingDockId: request.frame == nil ? dock.id : nil,
            relativeToDockId: request.relativeToDockId
        )
        return dock
    }

    func refreshWorkspaceFloatingDocks(
        for tabManager: TabManager,
        focusDockId: UUID? = nil,
        placingDockId: UUID? = nil,
        relativeToDockId: UUID? = nil
    ) {
        guard let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) else { return }
        context.installWorkspaceFloatingDockPresenterIfNeeded()
        context.workspaceFloatingDockPresenter?.refresh(
            focusDockId: focusDockId,
            placingDockId: placingDockId,
            relativeToDockId: relativeToDockId
        )
    }

    func preferredWorkspaceFloatingDock(in tabManager: TabManager) -> WorkspaceFloatingDock? {
        guard let workspace = tabManager.selectedWorkspace,
              let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) else {
            return nil
        }
        context.installWorkspaceFloatingDockPresenterIfNeeded()
        return context.workspaceFloatingDockPresenter?.preferredDock(in: workspace)
    }

    func customizeWorkspaceFloatingDockColor(in tabManager: TabManager) -> Bool {
        guard let dock = preferredWorkspaceFloatingDock(in: tabManager) else { return false }
        WorkspaceFloatingDockColorPanelController.shared.show(dock: dock) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            self.refreshWorkspaceFloatingDocks(for: tabManager)
        }
        return true
    }

    func resetWorkspaceFloatingDockColor(in tabManager: TabManager) -> Bool {
        guard let dock = preferredWorkspaceFloatingDock(in: tabManager) else { return false }
        dock.backgroundTintHex = nil
        refreshWorkspaceFloatingDocks(for: tabManager)
        return true
    }

    func refreshAllWorkspaceFloatingDocks() {
        for context in mainWindowContexts.values {
            context.installWorkspaceFloatingDockPresenterIfNeeded()
            context.workspaceFloatingDockPresenter?.refresh()
        }
    }
}

@MainActor
private final class WorkspaceFloatingDockColorPanelController: NSObject {
    static let shared = WorkspaceFloatingDockColorPanelController()

    private weak var dock: WorkspaceFloatingDock?
    private var onChange: (() -> Void)?

    func show(dock: WorkspaceFloatingDock, onChange: @escaping () -> Void) {
        self.dock = dock
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.title = String(
            localized: "floatingDock.colorPanel.title",
            defaultValue: "Floating Window Color"
        )
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = dock.backgroundTintHex.flatMap(NSColor.init(hex:))
            ?? WorkspaceFloatingDockBackdropAppearance.raycast(
                backgroundColor: GhosttyBackgroundTheme.currentColor()
            ).tintColor
            ?? .windowBackgroundColor
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorDidChange(_ sender: NSColorPanel) {
        guard let dock,
              let color = sender.color.usingColorSpace(.sRGB) else { return }
        dock.backgroundTintHex = color.hexString()
        onChange?()
    }
}
