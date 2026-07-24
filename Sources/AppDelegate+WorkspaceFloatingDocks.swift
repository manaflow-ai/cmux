import AppKit
import CmuxFoundation

let commandPaletteFloatingDockFocusSourceUserInfoKey = "floatingDockFocusSource"

struct CommandPaletteFloatingDockFocusSource {
    let store: DockSplitStore
    let panelId: UUID
    let window: NSWindow
    let intent: PanelFocusIntent
}

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

enum WorkspaceFloatingDockClosePolicy: Equatable {
    case confirmInteractive
    case force
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
        if let context = mainWindowContexts.values.first(where: { context in
            context.workspaceFloatingDockPresenter?.owns(window: window) == true
        }) {
            return context
        }
        if let parent = window.parent {
            return contextForMainTerminalWindow(parent)
        }
        return nil
    }

    func workspaceFloatingDock(owning window: NSWindow?) -> WorkspaceFloatingDock? {
        guard let context = contextForShortcutSourceWindow(window) else { return nil }
        return context.workspaceFloatingDockPresenter?.dock(owning: window)
    }

    func commandPaletteFloatingDockFocusSource(
        for window: NSWindow?
    ) -> CommandPaletteFloatingDockFocusSource? {
        guard let window,
              let dock = workspaceFloatingDock(owning: window),
              let panelId = dock.store.focusedPanelId,
              let panel = dock.store.panels[panelId] else { return nil }
        return CommandPaletteFloatingDockFocusSource(
            store: dock.store,
            panelId: panelId,
            window: window,
            intent: panel.captureFocusIntent(in: window)
        )
    }

    func workspaceFloatingDock(owning store: DockSplitStore) -> (
        dock: WorkspaceFloatingDock,
        workspace: Workspace,
        tabManager: TabManager
    )? {
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                guard let dock = workspace.floatingDocks.first(where: { $0.store === store }) else {
                    continue
                }
                return (dock, workspace, context.tabManager)
            }
        }
        return nil
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

    @discardableResult
    func focusWorkspaceFloatingDock(
        _ dock: WorkspaceFloatingDock,
        in workspace: Workspace,
        tabManager: TabManager
    ) -> Bool {
        guard workspace.floatingDocks.contains(where: { $0 === dock }) else { return false }
        if dock.isStashed {
            return setWorkspaceFloatingDockStashed(
                dock,
                in: workspace,
                tabManager: tabManager,
                stashed: false,
                focus: true
            )
        }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        refreshWorkspaceFloatingDocks(
            for: tabManager,
            focusDockId: dock.id
        )
        return true
    }

    @discardableResult
    func setWorkspaceFloatingDockStashed(
        _ dock: WorkspaceFloatingDock,
        in workspace: Workspace,
        tabManager: TabManager,
        stashed: Bool,
        focus: Bool
    ) -> Bool {
        guard workspace.floatingDock(id: dock.id) === dock else { return false }
        if stashed == dock.isStashed {
            if focus, !stashed {
                return focusWorkspaceFloatingDock(dock, in: workspace, tabManager: tabManager)
            }
            return true
        }

        let context = mainWindowContexts.values.first { $0.tabManager === tabManager }
        if focus, !stashed, tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        let isSelectedWorkspace = tabManager.selectedTabId == workspace.id
        if !stashed, isSelectedWorkspace {
            context?.installWorkspaceFloatingDockPresenterIfNeeded()
            context?.workspaceFloatingDockPresenter?.prepareRestoreAnimation(for: dock.id)
        }
        dock.setStashed(stashed)

        if stashed, isSelectedWorkspace {
            context?.installWorkspaceFloatingDockPresenterIfNeeded()
            if let presenter = context?.workspaceFloatingDockPresenter {
                presenter.animateStash(dock)
            } else {
                refreshWorkspaceFloatingDocks(for: tabManager)
            }
            return true
        }

        refreshWorkspaceFloatingDocks(
            for: tabManager,
            focusDockId: focus && !stashed ? dock.id : nil
        )
        return true
    }

    func stashPreferredWorkspaceFloatingDock(in tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.selectedWorkspace,
              let dock = preferredWorkspaceFloatingDock(in: tabManager) else { return false }
        return setWorkspaceFloatingDockStashed(
            dock,
            in: workspace,
            tabManager: tabManager,
            stashed: true,
            focus: false
        )
    }

    @discardableResult
    func restoreAllStashedWorkspaceFloatingDocks(
        in workspace: Workspace,
        tabManager: TabManager,
        focus: Bool
    ) -> Int? {
        guard tabManager.tabs.contains(where: { $0 === workspace }) else { return nil }
        let stashedDocks = workspace.floatingDocks.filter(\.isStashed)
        guard !stashedDocks.isEmpty else { return 0 }

        if focus, tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        let isSelectedWorkspace = tabManager.selectedTabId == workspace.id
        let context = mainWindowContexts.values.first { $0.tabManager === tabManager }
        if isSelectedWorkspace {
            context?.installWorkspaceFloatingDockPresenterIfNeeded()
            context?.workspaceFloatingDockPresenter?.prepareRestoreAnimations(
                for: stashedDocks.map(\.id)
            )
        }
        stashedDocks.forEach {
            $0.setStashed(false)
        }
        refreshWorkspaceFloatingDocks(
            for: tabManager,
            focusDockId: focus ? stashedDocks.first?.id : nil
        )
        return stashedDocks.count
    }

    @discardableResult
    func restoreAllStashedWorkspaceFloatingDocks(
        in tabManager: TabManager,
        focus: Bool
    ) -> Int? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return restoreAllStashedWorkspaceFloatingDocks(
            in: workspace,
            tabManager: tabManager,
            focus: focus
        )
    }

    func customizeWorkspaceFloatingDockColor(in tabManager: TabManager) -> Bool {
        guard let dock = preferredWorkspaceFloatingDock(in: tabManager) else { return false }
        WorkspaceFloatingDockColorPanelController.shared.show(dock: dock) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            guard let context = self.mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) else {
                return
            }
            context.workspaceFloatingDockPresenter?.updateTint(for: dock)
        }
        return true
    }

    func resetWorkspaceFloatingDockColor(in tabManager: TabManager) -> Bool {
        guard let dock = preferredWorkspaceFloatingDock(in: tabManager) else { return false }
        dock.backgroundTintHex = nil
        refreshWorkspaceFloatingDocks(for: tabManager)
        return true
    }

    @discardableResult
    func closeWorkspaceFloatingDock(
        _ dock: WorkspaceFloatingDock,
        in workspace: Workspace,
        tabManager: TabManager,
        policy: WorkspaceFloatingDockClosePolicy = .confirmInteractive
    ) -> Bool {
        guard workspace.floatingDock(id: dock.id) === dock else { return false }
        workspace.floatingDockCloseFailures.removeValue(forKey: dock.id)
        let needsNoteFlush = dock.store.needsAutosavingNoteFlush
        if !needsNoteFlush,
           policy == .confirmInteractive,
           !dock.store.confirmCloseAllPanels() { return false }
        if !needsNoteFlush {
            guard workspace.finalizeFloatingDockClose(id: dock.id) else { return false }
            refreshWorkspaceFloatingDocks(for: tabManager)
            return true
        }
        guard workspace.pendingFloatingDockCloseIds.insert(dock.id).inserted else { return true }
        Task { @MainActor [weak self, weak workspace, tabManager] in
            guard let workspace else { return }
            defer { workspace.pendingFloatingDockCloseIds.remove(dock.id) }
            guard let self else { return }
            if needsNoteFlush {
                guard await dock.store.flushPendingAutosavingNotes() else {
                    workspace.floatingDockCloseFailures[dock.id] = "note_save_failed"
                    NSSound.beep()
                    return
                }
                guard policy == .force || dock.store.confirmCloseAllPanels() else {
                    workspace.floatingDockCloseFailures[dock.id] = "close_cancelled"
                    return
                }
            }
            let closed = workspace.finalizeFloatingDockClose(id: dock.id)
            guard closed else {
                workspace.floatingDockCloseFailures[dock.id] = "dock_not_found"
                return
            }
            self.refreshWorkspaceFloatingDocks(for: tabManager)
        }
        return true
    }

    @discardableResult
    func closeAllWorkspaceFloatingDocks(
        in workspace: Workspace,
        tabManager: TabManager,
        policy: WorkspaceFloatingDockClosePolicy = .confirmInteractive
    ) -> Int? {
        let docks = workspace.floatingDocks
        for dock in docks {
            workspace.floatingDockCloseFailures.removeValue(forKey: dock.id)
        }
        let needsNoteFlush = docks.contains { $0.store.needsAutosavingNoteFlush }
        if !needsNoteFlush,
           policy == .confirmInteractive,
           !DockSplitStore.confirmCloseAllPanels(
               in: docks.map(\.store),
               confirmationManager: tabManager
           ) { return nil }
        if !needsNoteFlush {
            let closedCount = workspace.finalizeAllFloatingDockCloses()
            refreshWorkspaceFloatingDocks(for: tabManager)
            return closedCount
        }
        guard !workspace.isPendingCloseAllFloatingDocks else {
            return docks.count
        }
        workspace.isPendingCloseAllFloatingDocks = true
        Task { @MainActor [weak self, weak workspace, tabManager] in
            guard let workspace else { return }
            defer { workspace.isPendingCloseAllFloatingDocks = false }
            guard let self else { return }
            if needsNoteFlush {
                for dock in docks {
                    guard await dock.store.flushPendingAutosavingNotes() else {
                        workspace.floatingDockCloseFailures[dock.id] = "note_save_failed"
                        NSSound.beep()
                        return
                    }
                }
                if policy == .confirmInteractive,
                   !DockSplitStore.confirmCloseAllPanels(
                       in: docks.map(\.store),
                       confirmationManager: tabManager
                ) {
                    for dock in docks {
                        workspace.floatingDockCloseFailures[dock.id] = "close_cancelled"
                    }
                    return
                }
            }
            _ = workspace.finalizeAllFloatingDockCloses()
            self.refreshWorkspaceFloatingDocks(for: tabManager)
        }
        return docks.count
    }

    @discardableResult
    func closeAllWorkspaceFloatingDocks(
        in tabManager: TabManager,
        policy: WorkspaceFloatingDockClosePolicy = .confirmInteractive
    ) -> Int? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return closeAllWorkspaceFloatingDocks(
            in: workspace,
            tabManager: tabManager,
            policy: policy
        )
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
