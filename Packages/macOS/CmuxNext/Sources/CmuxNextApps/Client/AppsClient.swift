public import Foundation
public import Observation

/// Why a change was not sent.
public nonisolated enum AppsClientError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The supervisor is unreachable; nothing queues (OWNERSHIP-PRINCIPLES).
    case unavailable(AppsUnavailableReason)
    /// Install and grant changes come only from a user gesture.
    case needsUserOrigin
    case unknownApp(String)
    /// The supervisor refused or the call failed.
    case refused(AppsTransportError)

    public var description: String {
        switch self {
        case .unavailable(let reason): AppsStrings.unavailable(reason)
        case .needsUserOrigin: "installs and grants need a user gesture"
        case .unknownApp(let id): "no app \(id)"
        case .refused(let error): error.message
        }
    }
}

/// The client of the app supervisor (`apps-v1`): the install projection
/// (mirror + intent log), scene streams per mount, host states and logs.
/// The only writer of the projection is the supervisor: `apps-list` replies,
/// `apps-set` replies and the lists `apps-changed` triggers. Nothing is
/// written locally, and while the supervisor is unreachable every change
/// is refused at once.
@MainActor
@Observable
public final class AppsClient {
    public private(set) var availability: AppsAvailability
    public private(set) var projection = AppsProjection()
    /// The last refusal per app, until its next accepted change.
    public private(set) var rejections: [String: String] = [:]
    public private(set) var hostStates: [String: (state: AppHostState, reason: String?)] = [:]
    public private(set) var logs: [String: [AppLogLine]] = [:]
    @ObservationIgnored let transport: any AppsTransport
    @ObservationIgnored var mounts: [String: AppMount] = [:]
    @ObservationIgnored private var nextKey = 0
    @ObservationIgnored var nextLog = 1
    @ObservationIgnored var nextMount = 1
    /// Mount, unmount and user events go out one after another, in order.
    @ObservationIgnored var tail: Task<Void, Never>?
    @ObservationIgnored private var listing: Task<Void, Never>?
    /// Intents the supervisor has not answered, by key (in flight).
    @ObservationIgnored private var inFlight: Set<String> = []
    /// The availability epoch the client last connected for (one `connected()` per epoch).
    @ObservationIgnored private var connectedEpoch: Int?
    /// Apps whose log is followed (followed again after a reconnect).
    @ObservationIgnored var followed: Set<String> = []
    @ObservationIgnored let keyPrefix = UUID().uuidString.prefix(8).lowercased()
    static let logLimit = 500

    public init(transport: any AppsTransport) {
        self.transport = transport
        availability = transport.availability
        transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Starts following the supervisor.
    public func start() {
        transport.start()
        handle(.availability(transport.availability))
    }

    func setLogs(_ app: String, _ lines: [AppLogLine]) { logs[app] = lines }

    private var epoch: Int? { if case .available(let epoch) = availability { epoch } else { nil } }

    /// Visible records (mirror + pending intents), in the owner's order.
    public var apps: [AppRecord] { projection.visible }
    public func app(_ id: String) -> AppRecord? { projection.visible(id) }
    public var isAvailable: Bool { availability.isAvailable }
    public var unavailableReason: AppsUnavailableReason? {
        if case .unavailable(let reason) = availability { reason } else { nil }
    }

    // MARK: Changes

    /// Sends one `apps-set`. The change shows at once (pending intent) and
    /// leaves the log on the reply; a refusal returns the app to the mirror
    /// and records the reason in `rejections`.
    public func set(_ app: String, _ change: AppChange, origin: AppOrigin) async throws(AppsClientError) {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        if change.requiresUserOrigin, origin != .user { throw .needsUserOrigin }
        guard projection.visible(app) != nil else { throw .unknownApp(app) }
        nextKey += 1
        let intent = AppIntent(id: "\(keyPrefix)-\(nextKey)", app: app, change: change, origin: origin)
        projection.enqueue(intent)
        try await send(intent)
    }

    private func send(_ intent: AppIntent) async throws(AppsClientError) {
        let sentIn = epoch
        inFlight.insert(intent.id)
        defer { inFlight.remove(intent.id) }
        do throws(AppsTransportError) {
            let record = try await transport.set(app: intent.app, change: intent.change, origin: intent.origin, idempotencyKey: intent.id)
            projection.confirm(intent.id, record: record)
            rejections[intent.app] = nil
        } catch where error.connectionLost {
            // Sent, then the connection dropped: the intent stays and goes
            // again with its key on the next connection. When that one is
            // already up (a reconnect while this call was in flight), now.
            if let now = epoch, now != sentIn {
                // task-owner: one resend of an intent whose connection was replaced while it was in flight
                Task { [weak self] in try? await self?.send(intent) }
            }
            throw .unavailable(unavailableReason ?? .notConnected)
        } catch {
            projection.reject(intent.id)
            rejections[intent.app] = error.message
            // The owner may have committed something else meanwhile; list again.
            refresh()
            throw .refused(error)
        }
    }

    public func install(_ app: String) async throws(AppsClientError) { try await set(app, .install(true), origin: .user) }
    public func remove(_ app: String) async throws(AppsClientError) { try await set(app, .install(false), origin: .user) }

    /// Runs a catalog op of an app (palette, menus).
    public func run(app: String, op: String, args: AppJSON = .object([:])) async throws(AppsClientError) -> AppJSON {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        nextKey += 1
        do throws(AppsTransportError) {
            return try await transport.run(app: app, op: op, args: args, idempotencyKey: "\(keyPrefix)-\(nextKey)")
        } catch {
            throw .refused(error)
        }
    }

    // MARK: Supervisor events

    func handle(_ event: AppsTransportEvent) {
        switch event {
        case .availability(let next):
            availability = next
            if case .available(let epoch) = next {
                guard connectedEpoch != epoch else { return }
                connectedEpoch = epoch
                connected()
            } else {
                connectedEpoch = nil
                disconnected()
            }
        case .changed:
            refresh()
        case let .scene(mountID, ops, reset):
            guard let model = mounts[mountID]?.model else { return }
            if reset { model.reset() }
            model.apply(ops)
        case let .mountFailed(mountID, reason):
            mounts[mountID]?.model.status = .failed(reason)
        case let .host(app, state, reason):
            hostStates[app] = (state, reason)
        case let .log(app, level, message, date):
            appendLog(app, level: level, message: message, date: date)
        }
    }

    /// Lists again (the reply replaces the mirror unless a newer one landed).
    public func refresh() {
        guard availability.isAvailable else { return }
        let request = projection.listRequested()
        listing?.cancel()
        listing = Task { [weak self, transport] in
            guard let reply = try? await transport.list(), !Task.isCancelled else { return }
            self?.projection.applyList(reply.apps, revision: reply.revision, request: request)
        }
    }

    private func connected() {
        // A restarted supervisor may count revisions from scratch.
        projection.newConnection()
        hostStates.removeAll()
        refresh()
        remountAll()
        for app in followed { followLogs(app) }
        // Intents sent before the disconnect go again with their keys, one
        // after another in log order; the supervisor's idempotency makes a
        // repeat harmless.
        let resend = projection.pending.filter { !inFlight.contains($0.id) }
        guard !resend.isEmpty else { return }
        // task-owner: the ordered resend of pending intents after a reconnect
        Task { [weak self] in
            for intent in resend { try? await self?.send(intent) }
        }
    }

    private func disconnected() {
        listing?.cancel()
        let reason = AppsStrings.unavailable(unavailableReason ?? .notConnected)
        for mount in mounts.values { mount.model.status = .disconnected(reason) }
    }

}
