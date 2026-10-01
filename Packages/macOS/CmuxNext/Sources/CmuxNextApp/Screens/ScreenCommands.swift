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

    /// New screen in `workspace`, selected and focused when it lands. With a
    /// non-empty `spec` (or `cwd`) on a daemon with `screen-metadata-v1`, the
    /// metadata is applied in the same commit.
    static func create(in workspace: WorkspaceModel, daemon: DaemonService, content: WorkspaceContentController?,
                       spec: ScreenSpec = ScreenSpec(), cwd: String? = nil) {
        guard let connection = daemon.connection else { return }
        let handle = workspace.handle
        let intent = content?.beginFocusIntent()
        let extended = daemon.supports(DaemonCapabilities.screenMetadata)
        let options = SpawnOptions(cwd: cwd, workspace: workspace.key)
        Task {
            do {
                let surface: SurfaceID
                if extended {
                    surface = try await connection.newScreen(in: handle, spec: spec, options: options).surface
                } else {
                    surface = try await connection.newScreen(in: handle).surface
                }
                content?.expectFocus(on: surface, generation: intent)
            } catch {
                daemon.logger.error("new-screen failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A copy of `ref`'s screen right after it: same name, color, icon, and
    /// group, with a terminal in the directory of the screen's active tab.
    static func duplicate(_ ref: ScreenRef) {
        let screen = ref.screen
        let pane = screen.defaultPane.flatMap(screen.pane) ?? screen.panes.first
        let cwd = pane.flatMap { $0.tabs.indices.contains($0.defaultTabIndex) ? $0.tabs[$0.defaultTabIndex] : $0.tabs.first }?.cwd
        let spec = ScreenSpec(name: screen.name, color: screen.color, icon: screen.icon, index: ref.index + 1, group: screen.group)
        create(in: ref.workspace, daemon: ref.daemon, content: ref.content, spec: spec, cwd: cwd)
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
        let handle = screen.handle
        daemon.send("set-screen-metadata") { _ = try await $0.setScreenMetadata(handle, color: color.map(FieldUpdate.set) ?? .clear) }
    }

    static func setIcon(_ screen: ScreenModel, _ icon: String?, daemon: DaemonService) {
        let handle = screen.handle
        daemon.send("set-screen-metadata") { _ = try await $0.setScreenMetadata(handle, icon: icon.map(FieldUpdate.set) ?? .clear) }
    }

    static func setPinned(_ screen: ScreenModel, _ pinned: Bool, daemon: DaemonService) {
        let handle = screen.handle
        daemon.send("set-screen-pinned") { _ = try await $0.setScreenPinned(handle, pinned) }
    }

    // MARK: Order and moves

    /// Moves `screen` to `index` in its workspace (the daemon keeps pinned
    /// screens first and groups contiguous).
    static func move(_ screen: ScreenModel, to index: Int, daemon: DaemonService) {
        let handle = screen.handle
        daemon.send("move-screen") { _ = try await $0.moveScreen(handle, to: index) }
    }

    static func move(_ screen: ScreenModel, toWorkspace target: WorkspaceModel, daemon: DaemonService, services: AppServices) {
        let source = daemon.store.workspaces.first { $0.screens.contains { $0 === screen } }?.id
        guard !services.windows.crossesIncognito(from: source, to: target.id) else {
            return services.registry.refuse(RefusalStrings.incognitoMismatch)
        }
        let handle = screen.handle, workspace = target.handle
        daemon.send("move-screen") { _ = try await $0.moveScreen(handle, to: nil, workspace: workspace) }
    }

    /// Moves `screen` into a new workspace, shown in this window (a new
    /// window when `newWindow`).
    static func moveToNewWorkspace(_ screen: ScreenModel, daemon: DaemonService, services: AppServices, newWindow: Bool) {
        guard let connection = daemon.connection else { return }
        let handle = screen.handle
        let state = services.windows.active?.state
        let origin = services.windows.moveOrigin(of: daemon.store.workspaces.first { $0.screens.contains { $0 === screen } }?.id)
        Task {
            do {
                let result = try await connection.moveScreen(handle, to: nil, newWorkspace: true)
                guard let key = result.key?.rawValue else { return }
                services.windows.placeMoved(key, from: origin, preferred: state, newWindow: newWindow)
            } catch {
                daemon.logger.error("move-screen new_workspace failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
