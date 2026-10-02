import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Observation

/// `AppsTransport` over the local daemon's app supervisor (`apps-v1`). The
/// supervisor owns installs, grants and app hosts per machine; this Mac's
/// App Store and app sections talk to the local daemon (one owner, chosen
/// here). Availability follows the connection state and the capability:
/// connected with `apps-v1` is available (a new epoch per handshake, read
/// from the store's connection epoch so a reconnect inside one frame still
/// counts),
/// connected without it needs a newer cmux-tui, anything else is not
/// connected. Events arrive through the store's side events.
@MainActor
final class DaemonAppsTransport: AppsTransport {
    static let capability = "apps-v1"
    /// `apps-run` waits for the app's op; everything else uses the control-plane deadline.
    static let runTimeout: Duration = .seconds(30)

    private let daemon: DaemonService
    private(set) var availability: AppsAvailability = .unavailable(.notConnected)
    var onEvent: ((AppsTransportEvent) -> Void)?
    private var epoch = 0
    /// The store's connection epoch of the current availability epoch.
    private var storeEpoch = -1
    private var following: Task<Void, Never>?
    private var subscription: UInt64?

    init(daemon: DaemonService) {
        self.daemon = daemon
    }

    func start() {
        guard following == nil else { return }
        subscription = daemon.store.sideEvents.subscribe { [weak self] event in
            guard case .unknown(let name, let payload) = event, name.hasPrefix("apps-"),
                  let decoded = AppsEventDecoding.event(name: name, payload: payload) else { return }
            self?.onEvent?(decoded)
        }
        let daemon = daemon
        update(daemon.store.connectionState, storeEpoch: daemon.store.connectionEpoch)
        following = Task { [weak self] in
            for await (state, epoch) in Observations({ (daemon.store.connectionState, daemon.store.connectionEpoch) }) {
                self?.update(state, storeEpoch: epoch)
            }
        }
    }

    private func update(_ state: DaemonConnectionState, storeEpoch: Int) {
        let next: AppsAvailability
        switch state {
        case .connected(let identity):
            if identity.supports(Self.capability) {
                if case .available(let current) = availability, storeEpoch == self.storeEpoch { next = .available(epoch: current) } else {
                    epoch += 1
                    self.storeEpoch = storeEpoch
                    next = .available(epoch: epoch)
                }
            } else {
                next = .unavailable(.needsNewerDaemon)
            }
        case .connecting, .disconnected, .failed:
            next = .unavailable(.notConnected)
        }
        guard next != availability else { return }
        availability = next
        onEvent?(.availability(next))
    }

    // MARK: Commands

    private func send<R: DaemonRequest>(_ request: R, timeout: Duration? = nil) async throws(AppsTransportError) -> R.Response {
        guard availability.isAvailable, let connection = daemon.connection else { throw AppsTransportError(message: DaemonError.notConnected.description) }
        do {
            if let timeout { return try await connection.request(request, timeout: timeout) }
            return try await connection.request(request)
        } catch let error as DaemonError {
            if case .command(_, let message, let code) = error { throw AppsTransportError(code: code, message: message) }
            throw AppsTransportError(message: error.description)
        } catch {
            throw AppsTransportError(message: String(describing: error))
        }
    }

    func list() async throws(AppsTransportError) -> AppsListReply {
        AppsEventDecoding.list(try await send(AppsListRequest()))
    }

    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        let reply = try await send(AppsSetRequest(app: app, change: change, origin: origin, idempotencyKey: idempotencyKey))
        guard let record = AppRecord(json: AppJSON(reply)) else { throw AppsTransportError(message: "apps-set returned no app record") }
        return record
    }

    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
        _ = try await send(AppsMountRequest(app: app, interface: interface, mountID: mountID, context: context.daemonValue))
    }

    func unmount(mountID: String) async throws(AppsTransportError) {
        _ = try await send(AppsUnmountRequest(mountID: mountID))
    }

    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {
        _ = try await send(AppsDispatchRequest(mountID: mountID, node: node, event: event, payload: payload.daemonValue))
    }

    func run(app: String, op: String, args: AppJSON, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
        let reply = try await send(AppsRunRequest(app: app, op: op, args: args.daemonValue, idempotencyKey: idempotencyKey), timeout: Self.runTimeout)
        return AppJSON(reply)["value"] ?? .null
    }

    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] {
        AppsEventDecoding.logs(try await send(AppsLogsRequest(app: app, follow: follow)))
    }
}
