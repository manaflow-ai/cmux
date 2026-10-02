public import Foundation

/// What the supervisor pushes to the client.
public nonisolated enum AppsTransportEvent: Sendable, Hashable {
    case availability(AppsAvailability)
    /// `apps-changed {revision}`: the install mirror moved; list again.
    case changed(revision: UInt64?)
    /// `apps-scene {mount_id, ops}`.
    case scene(mountID: String, ops: [AppSceneOp])
    /// `apps-mount-failed {mount_id, reason}`.
    case mountFailed(mountID: String, reason: String)
    /// `apps-host {app, state, reason?}`.
    case host(app: String, state: AppHostState, reason: String?)
    /// `apps-log {app, level, message, ts_ms}` (after `apps-logs` with follow).
    case log(app: String, level: String, message: String, date: Date?)
}

/// The app supervisor as the feature module sees it (capability `apps-v1`,
/// plans/cmux-next/app-platform.md section 13.2). The App implements it over
/// the daemon client; `FakeAppsTransport` serves tests and the demo. Every
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
    func unmount(mountID: String) async throws(AppsTransportError)
    /// A user event on a mounted node (origin `user`: the supervisor mints the gesture token).
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError)
    /// Runs a catalog op of the app and waits for its result.
    func run(app: String, op: String, args: AppJSON, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine]
}
