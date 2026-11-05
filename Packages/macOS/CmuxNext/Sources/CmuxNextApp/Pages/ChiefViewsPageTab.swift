import CmuxNextActions
import CmuxNextAppCore
import CmuxNextChiefViews
import CmuxNextPages

/// The Chief view gallery (``ChiefViewsPage``, CmuxNextChiefViews) as a page tab: in the home
/// workspace it lands in Home's right column beside the Chief dock. The app passes its machines
/// and its navigation; the target serves the page.
enum ChiefViewsPageTab {
    static let page = InternalPageID(rawValue: "chief-views")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let host = ChiefViewsHost(
            workspaces: { [weak services] in services?.machines.allWorkspaces ?? [] },
            machineName: { [weak services] daemon in services.flatMap { ControlSessions.machineName(daemon, machines: $0.machines) } },
            openChat: { [weak services] in try services.map(DeepLinkNavigator.init)?.open(DeepLink(.session($0, turn: nil)), background: false) },
            revealTab: { [weak services] in services?.revealTab($0) ?? false },
            openURL: { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) })
        services.pages.register(WebPageTab(page, symbol: ChiefViewsPage.symbol, title: ChiefViewsPage.title) {
            ChiefViewsPage(host: host).makeView()
        })
        registry.bind(ChiefViewsPage.actionID, unavailable: { ChiefViewsPage.unavailableReason }, invoke: { [weak services] invocation in
            if let services { _ = services.pages.show(page, in: services.windows.active, focus: invocation.allowsViewChange) }
        })
        bindGalleryStage(into: registry, context: context)
        bindProjection(into: registry, context: context)
    }

    static let galleryStage = InternalPageID(rawValue: "gallery-stage")

    /// Gallery Stage (``GalleryStageTabs``, CmuxNextPages), the other DEV gallery: one more page tab per run.
    static func bindGalleryStage(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services, stages = GalleryStageTabs()
        services.pages.register(WebPageTab(galleryStage, symbol: GalleryStageTabs.symbol, title: GalleryStageTabs.title, view: { stages.view(for: $0) }))
        registry.bindEffect(ActionID(rawValue: GalleryStageTabs.actionID), unavailable: { GalleryStageTabs.unavailableReason }) { [weak services] invocation in
            let refusal = stages.open(entry: invocation["entry"]?.stringValue, variant: invocation["variant"]?.stringValue) {
                services?.pages.openNew(galleryStage, in: services?.windows.active, focus: invocation.allowsViewChange) != nil
            }
            return refusal.map { ActionEffect.refused($0) } ?? .done
        }
    }

    /// Projection windows (``WebProjection``, CmuxNextPages; HQ#7149 L10), the third DEV view: opens the window a
    /// projection names with a terminal in its worktree, and runs its test in a new workspace there, kept open.
    static func bindProjection(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services, projection = WebProjection.shared
        projection.windowID = { [weak services] in services?.windows.owner(of: $0)?.state.id }
        projection.isOpen = { [weak services] in services?.windows.controller(for: $0) != nil }
        registry.bindEffect(ActionID(rawValue: WebProjection.openID), unavailable: { WebProjection.unavailableReason }) { [weak services] invocation in
            do throws(WebProjection.Refusal) {
                let opened = try projection.open(server: invocation["server"]?.stringValue, worktree: invocation["worktree"]?.stringValue,
                                                 test: invocation["test"]?.stringValue)
                var spawn = WorkspaceSpawn(cwd: opened.worktree, name: WebProjection.workspaceName(opened.worktree))
                spawn.opensNewTabPage = true
                services?.windows.startDetached(spawn, into: opened.windowID)
                return .done
            } catch { return .refused(error.message) }
        }
        registry.bindEffect(ActionID(rawValue: WebProjection.runTestID), unavailable: { WebProjection.unavailableReason }) { [weak services] invocation in
            do throws(WebProjection.Refusal) {
                let run = try projection.testRun(in: services?.windows.active?.state.id, test: invocation["test"]?.stringValue)
                services?.windows.startDetached(WorkspaceSpawn(cwd: run.worktree, name: WebProjection.testName, command: run.test, keep: true),
                                                into: run.windowID)
                return .done
            } catch { return .refused(error.message) }
        }
    }
}

extension WindowManager {
    /// Starts a workspace create whose daemon part nobody waits for (``startWorkspace(_:on:into:frame:)``).
    fileprivate func startDetached(_ spawn: WorkspaceSpawn, into windowID: String) {
        let create = startWorkspace(spawn, into: windowID)
        Task { _ = try? await create() } // task-owner: the create's daemon part; its window shows when the daemon lists it
    }
}
