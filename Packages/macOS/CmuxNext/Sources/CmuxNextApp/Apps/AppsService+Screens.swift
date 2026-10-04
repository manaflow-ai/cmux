import AppKit
import CmuxNextApps
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Observation

/// Why an app screen did not open (`AppsService.ensureAppWorkspace`,
/// `showAppWorkspace`); the description is the localized reason.
enum AppScreenError: Error, Equatable, LocalizedError {
    /// The local daemon is not connected or does not serve `app-screens-v1`.
    case unsupported
    /// The store did not report the app's workspace within the wait.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupported: RefusalStrings.appScreensUnsupported
        case .timedOut: RefusalStrings.appWorkspaceTimedOut
        }
    }
}

/// App screens on the app side (plans/cmux-next/app-screens.md 3). The
/// store owns each app's workspace (`workspace.ensure_app`); this side
/// renders the `app` tab with the app's own page, the one view type an app
/// screen and an "Open as Tab" tab both show.
extension AppsService {
    /// How long `showAppWorkspace` waits for the tree to report the workspace.
    static let appWorkspaceWait: Duration = .seconds(10)

    /// The content of an `app` tab, one per tab: the app's page through its
    /// page provider (the same mount a page tab uses) once the registry
    /// lists the app, a placeholder until then (`AppTabView`).
    func tabView(for tab: TabModel) -> AppTabView? {
        guard tab.kind == .app, let appID = tab.snapshot.app else { return nil }
        if let entry = appTabs[tab.id], entry.app == appID { return entry.view }
        if appTabs[tab.id] != nil { releaseTabView(tab.id) }
        let key = tab.id
        let view = AppTabView(state: { [registry] in Self.tabState(registry, appID: appID) },
                              mount: { [unowned self] in pageProvider(for: appID).makeView(for: key, in: nil) },
                              unmount: { [unowned self] in pageProvider(for: appID).tabClosed(key) })
        appTabs[tab.id] = (appID, view)
        return view
    }

    /// What an app tab of `appID` can show now.
    static func tabState(_ registry: AppRegistry, appID: String) -> AppTabView.State {
        if let app = registry.app(appID), AppPanePage.opens(app) { return .ready }
        return registry.isLoaded ? .unavailable : .loading
    }

    func existingTabView(_ key: String) -> AppTabView? { appTabs[key]?.view }

    /// The tab closed or its surface was dropped: unmount its page.
    func releaseTabView(_ key: String) {
        appTabs.removeValue(forKey: key)?.view.stop()
    }

    /// Ensures `appID`'s app workspace on the local store
    /// (`workspace.ensure_app {app, kind}`, idempotent per app) and returns
    /// its workspace resource id. `cmux.apps.open {as: "screen"}` calls
    /// this, then `showAppWorkspace`.
    func ensureAppWorkspace(_ appID: String, kind: AppWorkspaceClient.Kind = .app) async throws -> ResourceID {
        let local = services.machines.local
        guard local.supports(DaemonCapabilities.shared.appScreens), let connection = local.connection else {
            throw AppScreenError.unsupported
        }
        guard let app = registry.app(appID), app.isActive else { throw AppsServiceError.unknownApp }
        return try await AppWorkspaceClient(connection).ensureApp(app.manifest.id, kind: kind).workspaceID
    }

    /// Shows the app workspace `id` in the active window once the local
    /// tree reports it (a just-created workspace arrives after its event).
    /// Throws `AppScreenError.timedOut` after `timeout` on `clock`, and
    /// `CancellationError` when the caller's task is cancelled.
    func showAppWorkspace(_ id: ResourceID, timeout: Duration = appWorkspaceWait,
                          clock: any Clock<Duration> = ContinuousClock()) async throws {
        let workspaceID = try await Self.waitForWorkspace(id, in: services.machines.local.store, timeout: timeout, clock: clock)
        if let state = services.windows.active?.state {
            services.windows.show(workspaceID: workspaceID, in: state)
        } else {
            services.windows.reveal(workspaceID: workspaceID)
        }
    }

    /// The `WorkspaceModel.id` of the workspace with resource id `id`, as
    /// soon as `store` has it. A one-shot `DemandTimer` on `clock` ends the
    /// wait with `AppScreenError.timedOut`; cancelling the caller ends it
    /// with `CancellationError`. The first of the three resumes the caller
    /// and stops the other two.
    static func waitForWorkspace(_ id: ResourceID, in store: DaemonStore, timeout: Duration,
                                 clock: any Clock<Duration>) async throws -> String {
        if let found = store.workspaces.first(where: { $0.resourceID == id })?.id { return found }
        let wait = WorkspaceWait(timer: DemandTimer(owner: "apps.showAppWorkspace", clock: clock))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait.begin(continuation)
                wait.observation = Task { @MainActor in
                    for await found in Observations({ store.workspaces.first { $0.resourceID == id }?.id }) {
                        if let found { return wait.finish(.success(found)) }
                    }
                }
                wait.timer.schedule(after: timeout) { @MainActor in wait.finish(.failure(AppScreenError.timedOut)) }
            }
        } onCancel: {
            // task-owner: one hop to the main actor to resume the cancelled caller
            Task { @MainActor in wait.finish(.failure(CancellationError())) }
        }
    }
}

/// One `waitForWorkspace` race on the main actor: the caller's
/// continuation, resumed once, and the observation and deadline it stops.
@MainActor
final class WorkspaceWait {
    let timer: DemandTimer
    var observation: Task<Void, Never>?
    private var continuation: CheckedContinuation<String, any Error>?

    init(timer: DemandTimer) {
        self.timer = timer
    }

    func begin(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        observation?.cancel()
        timer.cancel()
        continuation.resume(with: result)
    }
}
