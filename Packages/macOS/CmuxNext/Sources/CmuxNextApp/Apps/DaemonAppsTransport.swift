import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Observation
import os

/// `AppsTransport` over the local daemon's app supervisor (`apps-v1`). The
/// supervisor owns installs, grants and app hosts per machine; this Mac's
/// App Store, app sections and pages talk to the local daemon (one owner,
/// chosen here). Availability follows the connection state and the
/// capability: connected with `apps-v1` is available (a new epoch per
/// handshake, read from the store's connection epoch so a reconnect inside
/// one frame still counts), connected without it needs a newer cmux-tui,
/// anything else is not connected; an administrator's policy turns it off.
/// Events arrive through the store's side events; the provider channel
/// takes `apps-provider-*`.
@MainActor
final class DaemonAppsTransport: AppsTransport {
    nonisolated static let capability = "apps-v1"
    /// `apps-run` waits for the app's op; everything else uses the control-plane deadline.
    static let runTimeout: Duration = .seconds(30)
    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "apps")

    private let daemon: DaemonService
    let provider: AppsProviderChannel
    private(set) var availability: AppsAvailability = .unavailable(.notConnected)
    var onEvent: ((AppsTransportEvent) -> Void)?
    /// DisabledFeatures `apps`: the reason shown while it holds.
    var turnedOff: String? {
        didSet {
            guard turnedOff != oldValue else { return }
            provider.turnedOff = turnedOff
            update(daemon.store.connectionState, storeEpoch: daemon.store.connectionEpoch)
        }
    }
    private var epoch = 0
    /// The store's connection epoch of the current availability epoch.
    private var storeEpoch = -1
    private var following: Task<Void, Never>?
    private var subscription: UInt64?

    init(daemon: DaemonService) {
        self.daemon = daemon
        provider = AppsProviderChannel(link: .daemon(daemon))
    }

    func start() {
        guard following == nil else { return }
        subscription = daemon.store.sideEvents.subscribe { [weak self] event in
            guard case .unknown(let name, let payload) = event, DaemonSideEvents.isAppsEvent(name), let self else { return }
            if provider.handle(name: name, payload: payload) { return }
            if let decoded = AppsWireDecoding.event(name: name, payload: payload) { onEvent?(decoded) }
        }
        let daemon = daemon
        update(daemon.store.connectionState, storeEpoch: daemon.store.connectionEpoch)
        // task-owner: the transport (lives as long as the app); event-driven (Observation)
        following = Task { [weak self] in
            for await (state, epoch) in Observations({ (daemon.store.connectionState, daemon.store.connectionEpoch) }) {
                self?.update(state, storeEpoch: epoch)
            }
        }
    }

    private func update(_ state: DaemonConnectionState, storeEpoch: Int) {
        let capabilities: [String]? = if case .connected(let identity) = state { identity.capabilities } else { nil }
        let next: AppsAvailability
        if let reason = Self.unavailableReason(capabilities: capabilities) {
            next = .unavailable(reason)
        } else if case .available(let current) = availability, storeEpoch == self.storeEpoch {
            next = .available(epoch: current)
        } else {
            epoch += 1
            self.storeEpoch = storeEpoch
            next = .available(epoch: epoch)
        }
        // The provider follows the connection; while a policy turns apps off it refuses every call.
        if case .available(let epoch) = next { provider.connectionChanged(epoch: epoch) } else { provider.connectionChanged(epoch: nil) }
        let shown = turnedOff.map { AppsAvailability.unavailable(.turnedOff($0)) } ?? next
        guard shown != availability else { return }
        availability = shown
        onEvent?(.availability(shown))
    }

    /// Why the supervisor cannot be used: `capabilities` of the connected
    /// daemon, nil when none is connected.
    nonisolated static func unavailableReason(capabilities: [String]?) -> AppsUnavailableReason? {
        guard let capabilities else { return .notConnected }
        return capabilities.contains(capability) ? nil : .needsNewerDaemon
    }

    /// The `apps-run` origin: `user` only for a user origin on a connection
    /// the daemon verified as the cmux app (`client-hello`
    /// `user_origin_allowed`, P8), as `CloudAppLinks.wireOrigin` does;
    /// `script` for everything else.
    nonisolated static func wireOrigin(_ origin: AppOrigin, userOriginAllowed: Bool) -> AppsRunRequest.Origin {
        origin == .user && userOriginAllowed ? .user : .script
    }

    // MARK: Commands

    private func send<R: DaemonRequest>(_ request: R, timeout: Duration? = nil,
                                        whileTurnedOff: Bool = false) async throws(AppsTransportError) -> R.Response {
        guard availability.isAvailable || (whileTurnedOff && turnedOff != nil), let connection = daemon.connection else {
            throw AppsTransportError(message: DaemonError.notConnected.description, connectionLost: true)
        }
        do {
            if let timeout { return try await connection.request(request, timeout: timeout) }
            return try await connection.request(request)
        } catch let error as DaemonError {
            switch error {
            case .command(_, let message, let code, _, _): throw AppsTransportError(code: code, message: message)
            case .notConnected, .connectionClosed, .daemonShutdown: throw AppsTransportError(message: error.description, connectionLost: true)
            default: throw AppsTransportError(message: error.description)
            }
        } catch {
            throw AppsTransportError(message: String(describing: error))
        }
    }

    func list() async throws(AppsTransportError) -> AppsListReply {
        AppsWireDecoding.list(try await send(AppsListRequest()))
    }

    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        let request = AppsSetRequest(idempotencyKey: idempotencyKey, app: app, origin: origin.rawValue, installed: change.installed,
                                     enabled: change.enabled, hidden: change.hidden, sandboxed: change.sandboxed,
                                     grant: change.grant.map { AppsSetRequest.Grant(scope: $0.scope, granted: $0.granted) })
        guard let record = AppRecord(json: AppJSON(try await send(request))) else {
            throw AppsTransportError(message: AppsAppStrings.noRecord)
        }
        return record
    }

    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
        _ = try await send(AppsMountRequest(app: app, interface: interface, mountID: mountID, context: context.daemonValue))
    }

    func unmount(mountID: String) async throws(AppsTransportError) {
        _ = try await send(AppsUnmountRequest(mountID: mountID), whileTurnedOff: true)
    }

    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {
        _ = try await send(AppsDispatchRequest(mountID: mountID, node: node, event: event, payload: payload.daemonValue))
    }

    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
        let userAllowed = await daemon.connection?.userOriginAllowed == true
        let wire = Self.wireOrigin(origin, userOriginAllowed: userAllowed)
        Self.logger.info("apps-run \(app, privacy: .public) \(op, privacy: .public) origin=\(wire.rawValue, privacy: .public)")
        let request = AppsRunRequest(app: app, op: op, args: args.daemonValue, idempotencyKey: idempotencyKey, origin: wire)
        return AppJSON(try await send(request, timeout: Self.runTimeout).value)
    }

    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] {
        AppsWireDecoding.logs(try await send(AppsLogsRequest(app: app, follow: follow)))
    }
}
