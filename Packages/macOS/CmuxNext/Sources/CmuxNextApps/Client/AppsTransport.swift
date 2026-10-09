public import Foundation

/// What the supervisor pushes to the client.
public nonisolated enum AppsTransportEvent: Sendable, Hashable {
    case availability(AppsAvailability)
    /// `apps-changed {revision}`: the install mirror moved; list again.
    case changed(revision: UInt64?)
    /// `apps-scene {mount_id, ops, reset?}`. `reset` (the supervisor
    /// restarted the app host and re-mounted, after a crash or a grant
    /// change) means: drop the mount's tree and apply `ops` to an empty one.
    case scene(mountID: String, ops: [AppSceneOp], reset: Bool = false)
    /// `apps-mount-failed {mount_id, reason}`.
    case mountFailed(mountID: String, reason: String)
    /// `apps-host {app, state, reason?}`.
    case host(app: String, state: AppHostState, reason: String?)
    /// `apps-log {app, level, message, ts_ms}` (after `apps-logs` with follow).
    case log(app: String, level: String, message: String, date: Date?)
}

/// The app supervisor as the feature module sees it (capability `apps-v1`,
/// plans/cmux-next/app-platform.md section 13.2). The App implements it over
/// the daemon client; tests use a fake (Tests/CmuxNextAppsTests). Every
/// call is asynchronous with a deadline set by the implementation; none
/// blocks the main actor.
@MainActor
public protocol AppsTransport: AnyObject {
    var availability: AppsAvailability { get }
    /// Set by the client before `start()`; events arrive on the main actor in order.
    var onEvent: ((AppsTransportEvent) -> Void)? { get set }
    /// Begins following the daemon (availability events from here on).
    func start()
    func list() async throws(AppsTransportError) -> AppsListReply
    /// `apps-set`; returns the app's record after the commit.
    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord
    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError)
    /// Sent whenever a connection exists, also while the client shows the
    /// supervisor as unavailable (a policy turned apps off).
    func unmount(mountID: String) async throws(AppsTransportError)
    /// A user event on a mounted node (origin `user`: the supervisor mints the gesture token).
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError)
    /// Runs a catalog op of the app and waits for its result. `origin` is the
    /// caller's; the transport sends `user` only for a user origin on a
    /// connection the daemon verified as the cmux app.
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine]
}
