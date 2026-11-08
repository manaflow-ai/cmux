public import CMUXMobileCore
public import CmuxIrohTransport
public import Foundation

/// Publishes one v2 installation to the older same-account service, and reads
/// older peer records without turning them into trusted v2 device records.
/// The owning runtime keeps the endpoint, credentials and v2 authority.
public actor LegacyCompatibilityService {
    public static let v2Capability = "cmux.iroh-control.v2"

    /// Keeps the older directory's physical computer ID while using the current
    /// v2 endpoint key. This changes presentation identity, never v2 authority.
    /// Omitting deviceID reproduces the initial v2 publication for migration.
    public static func compatibilityIdentity(from identity: IrxIdentity, deviceID: String? = nil) -> IrxIdentity {
        func uuid(from bytes: Data) -> String {
            var value = Array(bytes.prefix(16))
            value += Array(repeating: 0, count: max(0, 16 - value.count))
            value[6] = (value[6] & 0x0f) | 0x40
            value[8] = (value[8] & 0x3f) | 0x80
            let hex = value.map { String(format: "%02x", $0) }.joined()
            return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        }
        let deviceID = deviceID ?? (UUID(uuidString: identity.deviceID) == nil
            ? uuid(from: identity.publicKeyData) : identity.deviceID)
        return IrxIdentity(privateKeyData: identity.privateKeyData,
            deviceID: deviceID,
            appInstanceID: uuid(from: Data(identity.publicKeyData.reversed())))
    }

    public struct Configuration: Sendable {
        public var brokerBaseURL: URL
        public var controlSocketURL: URL?
        public var clientNamespace: String
        public var tag: String
        public var platform: CmxIrohPlatform
        public var displayName: String?
        public var cacheDirectory: URL
        public var accountID: String
        public var identityGeneration: Int
        public var appVersion: String
        public var releaseTrack: String
        public var keychainAccessGroup: String?

        public init(brokerBaseURL: URL, controlSocketURL: URL? = nil,
                    clientNamespace: String, tag: String, platform: CmxIrohPlatform,
                    displayName: String?, cacheDirectory: URL, accountID: String,
                    identityGeneration: Int = 1, appVersion: String = "0",
                    releaseTrack: String = "default", keychainAccessGroup: String? = nil) {
            self.brokerBaseURL = brokerBaseURL
            self.controlSocketURL = controlSocketURL
            self.clientNamespace = clientNamespace
            self.tag = tag
            self.platform = platform
            self.displayName = displayName
            self.cacheDirectory = cacheDirectory
            self.accountID = accountID
            self.identityGeneration = identityGeneration
            self.appVersion = appVersion
            self.releaseTrack = releaseTrack
            self.keychainAccessGroup = keychainAccessGroup
        }
    }

    public struct Snapshot: Sendable {
        public let sequence: UInt64
        public let binding: IrxBindingSnapshot?
        /// Authenticated same-owner discovery, including explicit capability markers.
        public let discovery: CmxIrohDiscoveryResponse?
        /// Older peers only. Modern peers must pass the independent v2 authority.
        public let deviceList: IrxDeviceListSnapshot?
        public let stopped: Bool
    }

    public enum Failure: Error, Sendable {
        case invalidIdentity
        case stopped
        case notStarted
    }

    /// Existing trust APIs support the historical application protocol listener.
    public nonisolated let broker: IrxBrokerService
    /// Synchronous authority seam required by IROH's admission callback.
    public nonisolated let listCurrent = IrxDeviceListCurrent()
    private let configuration: Configuration
    private let identity: IrxIdentity
    private let previousDeviceID: String?
    private let brokerConfiguration: IrxBrokerService.Configuration
    private let accessTokenPair: @Sendable () async throws -> (access: String, refresh: String)?
    private let journal: IrxJournal
    private var directory = LegacyCompatibilityDirectory()
    private var control: IrxControlPlaneClient?
    private var binding: IrxBindingSnapshot?
    private var discovery: CmxIrohDiscoveryResponse?
    private var startup: Task<Void, any Error>?
    private var refresh: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var sequence: UInt64 = 0
    private var stopped = false
    private var started = false
    private var relayURL: String?

    /// Use the v2 key with stable UUID device and app-instance identifiers. The
    /// namespace is the real app namespace required by older discovery filters.
    public init(configuration: Configuration, identity: IrxIdentity, previousDeviceID: String? = nil,
                accessTokenPair: @escaping @Sendable () async throws -> (access: String, refresh: String)?,
                journal: IrxJournal) throws {
        guard UUID(uuidString: identity.deviceID) != nil,
              UUID(uuidString: identity.appInstanceID) != nil,
              !configuration.accountID.isEmpty else { throw Failure.invalidIdentity }
        self.configuration = configuration
        self.identity = identity
        self.previousDeviceID = previousDeviceID
        self.accessTokenPair = accessTokenPair
        self.journal = journal
        let brokerConfiguration = IrxBrokerService.Configuration(
            baseURL: configuration.brokerBaseURL, clientNamespace: configuration.clientNamespace,
            tag: configuration.tag, platform: configuration.platform, displayName: configuration.displayName,
            cacheDirectory: configuration.cacheDirectory,
            identityGeneration: configuration.identityGeneration, accountID: configuration.accountID,
            keychainAccessGroup: configuration.keychainAccessGroup,
            additionalCapabilities: [Self.v2Capability], cacheIdentity: identity.endpointIDHex)
        self.brokerConfiguration = brokerConfiguration
        broker = try IrxBrokerService(configuration: brokerConfiguration,
            identity: identity, accessTokenPair: accessTokenPair, journal: journal)
    }

    /// Registers once per service lifecycle, then starts the older directory
    /// subscription. Call independently of v2 enrollment, never as auth fallback.
    public func start() async throws {
        guard !stopped else { throw Failure.stopped }
        if started { return }
        if let startup { return try await startup.value }
        let task = Task { [weak self] in
            guard let self else { throw Failure.stopped }
            try await self.performStart()
        }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func performStart() async throws {
        let registered = try await registerPreservingComputerID()
        guard !stopped, !Task.isCancelled else { throw Failure.stopped }
        binding = registered
        started = true
        publish()
        await startControl()
        do {
            _ = try await discover(maximumAge: 0)
        } catch {
            started = false
            let oldControl = control
            control = nil
            await oldControl?.stop()
            binding = nil
            publish()
            throw error
        }
    }

    /// The first v2 release published the installation ID in the account
    /// directory. If that exact key already occupies the erroneous slot, prove
    /// ownership of it, retire it, and retry the physical-ID registration.
    /// A failed/lost reply is safe to retry on the next startup. Never search by
    /// display name or revoke another endpoint, namespace, tag, or account.
    private func registerPreservingComputerID() async throws -> IrxBindingSnapshot {
        do {
            return try await broker.register(pairingEnabled: configuration.platform == .mac,
                relayURLHint: relayURL)
        } catch CmxIrohTrustBrokerClientError.rejected(statusCode: 409, code: "endpoint_already_bound") {
            guard let previousDeviceID, previousDeviceID != identity.deviceID,
                  UUID(uuidString: previousDeviceID) != nil,
                  !stopped, !Task.isCancelled else {
                throw CmxIrohTrustBrokerClientError.rejected(statusCode: 409, code: "endpoint_already_bound")
            }
            let previous = IrxIdentity(privateKeyData: identity.privateKeyData,
                deviceID: previousDeviceID, appInstanceID: identity.appInstanceID)
            let previousBroker = try IrxBrokerService(configuration: brokerConfiguration,
                identity: previous, accessTokenPair: accessTokenPair, journal: journal)
            do {
                let old = try await previousBroker.register(
                    pairingEnabled: configuration.platform == .mac, relayURLHint: relayURL)
                guard !stopped, !Task.isCancelled else { throw Failure.stopped }
                try await previousBroker.revoke(bindingID: old.bindingID)
                await previousBroker.deactivate()
                guard !stopped, !Task.isCancelled else { throw Failure.stopped }
                journal.record("legacy-compat", "computer-id-migrated", [
                    "previous_device": previousDeviceID, "device": identity.deviceID,
                    "endpoint": identity.endpointIDHex
                ])
            } catch {
                await previousBroker.deactivate()
                throw error
            }
            return try await broker.register(pairingEnabled: configuration.platform == .mac,
                relayURLHint: relayURL)
        }
    }

    /// Ends this owner permanently. A later account/team uses a new service.
    ///
    /// When requested, the binding is revoked after local state is cleared. The
    /// local clear happens first so a delayed broker response can never keep a
    /// stale compatibility identity authoritative. Revocation is best effort
    /// and bounded because teardown must not hold the host lifecycle open on a
    /// network failure.
    public func stop(revokeOwnBinding: Bool = false) async {
        guard !stopped else { return }
        let bindingToRevoke = revokeOwnBinding ? binding?.bindingID : nil
        stopped = true
        started = false
        startup?.cancel()
        startup = nil
        refresh?.cancel()
        refresh = nil
        directory.stop()
        listCurrent.clear()
        binding = nil
        discovery = nil
        let oldControl = control
        control = nil
        publish()
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        await oldControl?.stop()
        if let bindingToRevoke {
            let broker = self.broker
            _ = try? await withIrxDeadline(.seconds(3), onTimeout: {}, operation: {
                try await broker.revoke(bindingID: bindingToRevoke)
                return true
            })
        }
        await broker.deactivate()
    }

    public func snapshot() -> Snapshot {
        Snapshot(sequence: sequence, binding: binding, discovery: discovery,
            deviceList: directory.current, stopped: stopped)
    }

    /// Each subscriber gets the current snapshot and every subsequent change.
    public func events() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot())
        if stopped { continuation.finish() }
        else {
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        }
        return stream
    }

    public func discover(maximumAge: TimeInterval = 5) async throws -> CmxIrohDiscoveryResponse {
        guard !stopped else { throw Failure.stopped }
        guard started else { throw Failure.notStarted }
        let value = try await broker.discover(maximumAge: maximumAge)
        guard !stopped, !Task.isCancelled else { throw Failure.stopped }
        discovery = value
        directory.excludeV2Endpoints(Set(value.bindings.filter {
            $0.capabilities.contains(Self.v2Capability)
        }.map { $0.endpointID.endpointID }))
        listCurrent.replace(directory.current)
        publish()
        return value
    }

    /// Denies these modern keys through older admission, including revoked keys.
    /// Exclusions remain for this service's lifetime even when snapshots shrink.
    public func excludeV2Endpoints(_ endpoints: Set<String>) {
        guard !stopped else { return }
        directory.excludeV2Endpoints(endpoints)
        listCurrent.replace(directory.current)
        publish()
    }

    public func publishRelayHint(_ relayURL: String?) async throws {
        guard !stopped else { throw Failure.stopped }
        self.relayURL = relayURL
        guard started else { return }
        try await broker.registerHintIfNeeded(pairingEnabled: configuration.platform == .mac,
            relayURLHint: relayURL)
        guard !stopped else { throw Failure.stopped }
        if let relayURL { await control?.publishHint(homeRelayURL: relayURL) }
    }

    public func revokeBinding(_ bindingID: String) async throws {
        guard !stopped else { throw Failure.stopped }
        try await broker.revoke(bindingID: bindingID)
        guard !stopped else { throw Failure.stopped }
        await broker.invalidateDiscoverySnapshot()
        _ = try await discover(maximumAge: 0)
    }

    /// Resumes directory correction after iOS foreground/network changes.
    public func kick() async {
        guard !stopped else { return }
        await control?.kick()
        requestDiscoveryRefresh()
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func startControl() async {
        guard control == nil, let socketURL = configuration.controlSocketURL else { return }
        let client = IrxControlPlaneClient(configuration: .init(
            socketURL: socketURL.appendingPathComponent("v1/control/socket"),
            endpointIDHex: identity.endpointIDHex, wantPasses: false,
            cacheDirectory: configuration.cacheDirectory,
            clientInfo: .init(deviceID: identity.deviceID, platform: configuration.platform == .mac ? "mac" : "ios",
                appVersion: configuration.appVersion, releaseTrack: configuration.releaseTrack,
                capabilities: [Self.v2Capability, "legacy-compat"]), clientNamespace: configuration.clientNamespace),
            tokenPair: accessTokenPair,
            handlers: .init(onRelayPasses: { _ in true }, onHintUpdate: { [weak self] _, relay in
                guard let self else { return false }
                await self.handleHint(relay)
                return true
            }, onDirectory: { [weak self] _ in
                guard let self else { return false }
                await self.requestDiscoveryRefresh()
                return true
            }, onSnapshotComplete: { [weak self] _ in await self?.requestDiscoveryRefresh() },
                onDirectoryFact: { [weak self] fact in
                    guard let self else { return false }
                    await self.apply(fact)
                    return true
                }, onFreshness: { [weak self] rev, date in
                    await self?.restamp(revision: rev, issuedAt: date)
                }), journal: journal)
        control = client
        await client.start()
    }

    private func handleHint(_ relay: String) async {
        relayURL = relay
        await requestDiscoveryRefresh()
    }

    private func requestDiscoveryRefresh() {
        guard refresh == nil, started, !stopped else { return }
        refresh = Task { [weak self] in
            guard let self else { return }
            defer { Task { await self.clearRefresh() } }
            _ = try? await self.discover(maximumAge: 0)
        }
    }

    private func clearRefresh() { refresh = nil }

    private func apply(_ fact: IrxCtlDirectoryFact) {
        let entries = Dictionary(uniqueKeysWithValues: fact.payload.bindings.map { item in
            (item.endpointID, IrxDeviceListEntry(deviceID: item.deviceID, status: item.status ?? "active",
                revoked: item.revoked ?? false, appVersion: item.appVersion,
                releaseTrack: item.releaseTrack, capabilities: item.capabilities,
                relayURLHint: item.homeRelayURL, bindingID: item.bindingID,
                tag: item.instanceTag, identityGeneration: item.identityGeneration))
        })
        directory.apply(IrxDeviceListSnapshot(entries: entries, rev: fact.rev,
            issuedAt: fact.payload.issuedAt ?? Date(), ttlSeconds: fact.payload.ttlSeconds ?? 3600,
            minimumSupportedMacVersion: fact.payload.minimumSupportedVersion?.mac,
            receivedAtWall: Date(), receivedAtMonotonic: .now))
        listCurrent.replace(directory.current)
        publish()
    }

    private func restamp(revision: Int, issuedAt: Date) {
        directory.restamp(revision: revision, issuedAt: issuedAt,
            receivedAtWall: Date(), receivedAtMonotonic: .now)
        listCurrent.replace(directory.current)
        publish()
    }

    private func publish() {
        sequence &+= 1
        let value = snapshot()
        subscribers.values.forEach { $0.yield(value) }
    }
}
