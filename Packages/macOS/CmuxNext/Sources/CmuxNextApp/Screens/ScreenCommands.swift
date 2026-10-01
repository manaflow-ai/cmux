import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

/// The one mutation path for screens: the screen bar, the palette, context
/// menus, shortcuts, and the CLI all call these (cmux-shared-behavior).
/// Every change is one daemon command; the store echo updates the bar and
/// the layout. Failures are logged and leave the daemon's state on screen.
@MainActor
enum ScreenCommands {
    // MARK: Selection

    /// Shows `screen` in `content`; the layout's screen intent focuses the
    /// screen's most recently focused pane
    /// (`WorkspaceContentController.focusRememberedPane`).
    static func select(_ id: LayoutScreenID, in content: WorkspaceContentController) {
        content.layoutModel.selectScreen(id)
    }

    /// Selects the neighbor `offset` screens away, wrapping.
    static func selectAdjacent(_ offset: Int, in content: WorkspaceContentController) {
        let screens = content.layoutModel.screens
        guard screens.count > 1 else { return }
        let index = screens.firstIndex { $0.id == content.layoutModel.activeScreenID } ?? 0
        select(screens[((index + offset) % screens.count + screens.count) % screens.count].id, in: content)
    }

    // MARK: Create and close

    /// New screen in `workspace`, selected and focused when it lands. A
    /// non-empty `spec` is applied right after it is created (name, then the
    /// screen state; `DaemonConnection.newScreen(in:spec:)`).
    static func create(in workspace: WorkspaceModel, daemon: DaemonService, content: WorkspaceContentController?,
                       spec: ScreenSpec = ScreenSpec()) {
        guard let connection = daemon.connection else { return }
        let handle = workspace.handle
        let intent = content?.beginFocusIntent()
        Task {
            do {
                let surface = try await connection.newScreen(in: handle, spec: spec).surface
                content?.expectFocus(on: surface, generation: intent)
            } catch {
                daemon.logger.error("new-screen failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A copy of `ref`'s screen right after it: same name, color, icon, and
    /// group.
    static func duplicate(_ ref: ScreenRef) {
        let screen = ref.screen
        let spec = ScreenSpec(name: screen.name, color: screen.color, icon: screen.icon, index: ref.index + 1, group: screen.group)
        create(in: ref.workspace, daemon: ref.daemon, content: ref.content, spec: spec)
    }

    /// Closes screens. Their terminals detach and are reaped after the grace
    /// period, so Reopen Closed Screen can bring the first one back.
    static func close(_ screens: [ScreenModel], in workspace: WorkspaceModel, daemon: DaemonService, services: AppServices) {
        for screen in screens {
            services.closedScreens.record(screen, in: workspace)
            let handle = screen.handle
            daemon.send("close-screen") { try await $0.closeScreen(handle) }
        }
    }

    // MARK: Metadata

    static func rename(_ screen: ScreenModel, to name: String, daemon: DaemonService) {
        let handle = screen.handle
        daemon.send("rename-screen") { try await $0.renameScreen(handle, to: name) }
    }

    static func setColor(_ screen: ScreenModel, _ color: String?, daemon: DaemonService) {
        guard let id = screen.resourceID else { return }
        daemon.send("screen.update") { try await $0.updateScreen(id, color: color.map(FieldUpdate.set) ?? .clear) }
    }

    static func setIcon(_ screen: ScreenModel, _ icon: String?, daemon: DaemonService) {
        guard let id = screen.resourceID else { return }
        daemon.send("screen.update") { try await $0.updateScreen(id, icon: icon.map(FieldUpdate.set) ?? .clear) }
    }

    static func setPinned(_ screen: ScreenModel, _ pinned: Bool, daemon: DaemonService) {
        guard let id = screen.resourceID else { return }
        daemon.send("screen.update") { try await $0.updateScreen(id, pinned: pinned) }
    }

    // MARK: Order and moves

    /// Moves `screen` to `index` in its workspace (the daemon keeps pinned
    /// screens first and groups contiguous).
    static func move(_ screen: ScreenModel, to index: Int, daemon: DaemonService) {
        guard let id = screen.resourceID else { return }
        daemon.send("screen.move") { try await $0.moveScreen(id, to: index) }
    }
}
