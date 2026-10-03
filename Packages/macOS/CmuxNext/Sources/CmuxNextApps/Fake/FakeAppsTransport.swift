public import Foundation

/// An in-memory app supervisor for tests and the demo: the bundled sample
/// manifests as available apps, the `apps-set` rules of the real one
/// (install and grant changes need origin `user`, grants only for requested
/// scopes), a revision bumped per commit with `apps-changed`, and a static
/// sample scene per mount. Tests can hold replies, refuse changes and drop
/// the connection.
@MainActor
public final class FakeAppsTransport: AppsTransport {
    public private(set) var availability: AppsAvailability
    public var onEvent: ((AppsTransportEvent) -> Void)?
    public private(set) var records: [AppRecord]
    public private(set) var revision: UInt64 = 1
    /// Refuses a change before it commits (nil lets it through).
    public var refusal: ((String, AppChange, AppOrigin) -> AppsTransportError?)?
    /// While true, `apps-set` replies wait for `releaseReplies()`.
    public var holdsReplies = false
    public private(set) var mounted: [String: (app: String, interface: String, context: AppJSON)] = [:]
    public private(set) var dispatched: [(mountID: String, node: String, event: String)] = []
    public private(set) var seenKeys: [String] = []
    public private(set) var listCalls = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var epoch = 1

    public init(records: [AppRecord] = FakeAppsTransport.sampleRecords(), available: Bool = true) {
        self.records = records
        availability = available ? .available(epoch: 1) : .unavailable(.needsNewerDaemon)
    }

    /// The bundled first-party apps installed for everyone (source default,
    /// required scopes granted), then the samples: agent-status as a default
    /// app, the others available and not installed. Reads the bundled manifests from
    /// disk (tests and demos only, never the shipping store path).
    public static func sampleRecords() -> [AppRecord] {
        let firstParty = AppPlatformResources.firstPartyManifests().map { sample in
            var record = AppRecord(manifest: sample.manifest, tier: .firstParty, installed: true, source: .default,
                                   grants: Set(sample.manifest.scopes.map(\.scope)))
            record.bundleDirectory = sample.directory
            return record
        }
        return firstParty + AppPlatformResources.sampleManifests().map { sample in
            let manifest = sample.manifest
            let isDefault = manifest.id == "cmux/agent-status"
            var record = AppRecord(manifest: manifest, tier: AppStoreTier.local(manifest), installed: isDefault,
                                   source: isDefault ? .default : .bundled, grants: isDefault ? Set(manifest.scopes.map(\.scope)) : [])
            record.bundleDirectory = sample.directory
            return record
        }
    }

    public func start() {}

    /// Drops or restores the connection (a restored one is a new epoch).
    public func setAvailable(_ available: Bool, reason: AppsUnavailableReason = .notConnected) {
        if available {
            epoch += 1
            availability = .available(epoch: epoch)
        } else {
            availability = .unavailable(reason)
        }
        onEvent?(.availability(availability))
    }

    public func releaseReplies() {
        let waiting = held
        held.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    public func list() async throws(AppsTransportError) -> AppsListReply {
        try requireAvailable()
        listCalls += 1
        return AppsListReply(revision: revision, apps: records)
    }

    public func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        try requireAvailable()
        if holdsReplies {
            await withCheckedContinuation { held.append($0) }
            // The connection dropped while the request waited.
            try requireAvailable()
        }
        guard let index = records.firstIndex(where: { $0.id == app }) else { throw AppsTransportError(code: "apps.unknown", message: "no app \(app)") }
        if seenKeys.contains(idempotencyKey) { return records[index] }
        if change.requiresUserOrigin, origin != .user {
            throw AppsTransportError(code: "apps.origin", message: "installs and grants need a user gesture")
        }
        if let grant = change.grant, !(records[index].manifest.scopes + records[index].manifest.optionalScopes).contains(where: { $0.scope == grant.scope }) {
            throw AppsTransportError(code: "apps.scope", message: "\(app) does not request \(grant.scope)")
        }
        if let refusal = refusal?(app, change, origin) { throw refusal }
        seenKeys.append(idempotencyKey)
        var next = change.applied(to: records[index])
        if change.installed == true, next.source == .bundled { next.source = .user }
        if change.installed == true, next.tier != .unverified { next.grants = Set(next.manifest.scopes.map(\.scope)) }
        revision += 1
        next.revision = revision
        records[index] = next
        let revision = revision
        // task-owner: the commit's apps-changed event, after the reply like the daemon's event stream
        Task { @MainActor [weak self] in self?.onEvent?(.changed(revision: revision)) }
        return next
    }

    public func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {
        try requireAvailable()
        guard let record = records.first(where: { $0.id == app }) else { throw AppsTransportError(code: "apps.unknown", message: "no app \(app)") }
        let preview = context["preview"]?.boolValue == true
        guard record.installed || preview else { throw AppsTransportError(code: "apps.notInstalled", message: "\(app) is not installed") }
        guard record.enabled || preview else { throw AppsTransportError(code: "apps.disabled", message: "\(app) is disabled") }
        mounted[mountID] = (app, interface, context)
        let ops = FakeAppScenes.scene(for: record, interface: interface, preview: preview)
        // task-owner: the mount's first scene batch, like the supervisor's apps-scene event
        Task { @MainActor [weak self] in self?.onEvent?(.scene(mountID: mountID, ops: ops)) }
    }

    public func unmount(mountID: String) async throws(AppsTransportError) {
        mounted[mountID] = nil
    }

    public func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {
        try requireAvailable()
        dispatched.append((mountID, node, event))
    }

    public func run(app: String, op: String, args: AppJSON, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
        try requireAvailable()
        throw AppsTransportError(code: "operation.unsupported", message: "\(op) is not supported by the demo supervisor")
    }

    public func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] {
        try requireAvailable()
        return [AppLogLine(id: 1, date: nil, level: "info", message: "started"), AppLogLine(id: 2, date: nil, level: "info", message: "mounted")]
    }

    /// The supervisor restarted the app host (crash, grant change) and
    /// re-mounted `mountID`: its first scene batch resets the tree (tests).
    public func restartHost(mountID: String) {
        guard let mount = mounted[mountID], let record = records.first(where: { $0.id == mount.app }) else { return }
        onEvent?(.scene(mountID: mountID, ops: FakeAppScenes.scene(for: record, interface: mount.interface, preview: false), reset: true))
    }

    /// Pushes an event as the daemon would (tests).
    public func emit(_ event: AppsTransportEvent) { onEvent?(event) }

    /// Replaces a record as if another client changed it (tests).
    public func commitElsewhere(_ record: AppRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        revision += 1
        onEvent?(.changed(revision: revision))
    }

    private func requireAvailable() throws(AppsTransportError) {
        guard availability.isAvailable else { throw AppsTransportError(message: "not connected", connectionLost: true) }
    }
}
