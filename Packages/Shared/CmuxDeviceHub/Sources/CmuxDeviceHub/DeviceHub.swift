public import Foundation
public import Observation

/// The signed-in user's devices as this app sees them: who is online, who
/// shares Mac Screen, permissions, relays, requests waiting for an answer,
/// approved sessions' tickets and the audit log. It registers this device
/// when started (on sign-in), keeps the User DO socket open, and refetches
/// whatever a push says changed. Intents call the hub and refetch; the UI
/// reads the properties.
@MainActor @Observable
public final class DeviceHub {
    public enum Status: Sendable, Equatable {
        /// Not started (signed out, or the hub is not configured).
        case idle
        case starting
        /// This device is registered.
        case ready
        case failed(String)
    }

    public private(set) var status: Status = .idle
    public private(set) var connection: DeviceHubSocket.State = .disconnected
    public private(set) var me: HubMe?
    public private(set) var devices: [HubDevice] = []
    /// Permissions by host id (`GET /v1/permissions?host=`); this device's are fetched on every refresh.
    public private(set) var permissions: [String: [HubPermission]] = [:]
    public private(set) var relays: [HubRelay] = []
    /// The opened relay secrets this device holds, by relay id: what the Keychain
    /// holds, loaded off the main actor by ``refreshRelays()`` (a Keychain read can
    /// take seconds), and kept in step by ``saveRelay(id:name:urls:secret:enabled:priority:)``
    /// and ``deleteRelay(_:)``. Views read this, never the store.
    private var openedSecrets: [String: RelaySecret] = [:]
    /// Requests to this device (as host) that wait for ``decide(_:decision:scope:)``.
    public private(set) var pendingRequests: [SessionRequest] = []
    /// Approved sessions' tickets by session id, until the session is denied, revoked or ends.
    public private(set) var tickets: [String: SessionTicket] = [:]
    /// Newest first, as last fetched by ``refreshAudit(limit:)``.
    public private(set) var audit: [AuditEntry] = []
    public private(set) var lastError: DeviceHubError?
    /// Counts the pushes that changed something (every type but `pong`), so
    /// a view can follow what the hub has no push for (the audit log).
    public private(set) var pushCount = 0

    /// Session pushes (`session.*`) in the order they arrive, for the Mac Screen layer:
    /// a ticket starts signaling; a revocation or end closes the peer connection at once.
    @ObservationIgnored public var onSessionPush: ((DeviceHubPush) -> Void)?
    /// The name this device registers with.
    @ObservationIgnored public var deviceName: String

    @ObservationIgnored public let client: DeviceHubClient
    @ObservationIgnored let socket: DeviceHubSocket
    /// The relay secret store (the Keychain): every call off the main actor, one at a time.
    @ObservationIgnored let vault: RelaySecretVault
    @ObservationIgnored let platform: DevicePlatform
    @ObservationIgnored let now: @Sendable () -> Date
    /// Makes a new identity when the hub refuses this one (`device_removed`, `device_key_mismatch`).
    @ObservationIgnored let renewIdentity: (@Sendable () throws -> DeviceIdentity)?
    @ObservationIgnored private var socketTask: Task<Void, Never>?
    /// Relays this device saved that no listing has shown yet (kept from pruning).
    @ObservationIgnored var savedNotListed: Set<String> = []
    /// Bumped by start and stop: an answer from an older run is dropped.
    @ObservationIgnored private var generation = 0

    public init(client: DeviceHubClient, socket: DeviceHubSocket? = nil, secrets: any RelaySecretStore, deviceName: String,
                platform: DevicePlatform = .macos, renewIdentity: (@Sendable () throws -> DeviceIdentity)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.socket = socket ?? DeviceHubSocket(connector: URLSessionDeviceHubConnector(client: client))
        vault = RelaySecretVault(store: secrets)
        self.deviceName = deviceName
        self.platform = platform
        self.renewIdentity = renewIdentity
        self.now = now
    }

    /// The app's hub: its Secure Enclave identity under `<bundleIdentifier>.device-hub`
    /// (loaded off the main thread, renewed when the hub refuses it), relay secrets
    /// in the same Keychain service, and `tokens` for the account (CloudAuth's access token).
    public static func forApp(baseURL: URL, bundleIdentifier: String, deviceName: String, platform: DevicePlatform = .macos,
                              tokens: any DeviceHubAccountTokenProvider) async throws -> DeviceHub {
        let identity = try await loadIdentity { try DeviceIdentity.forApp(bundleIdentifier: bundleIdentifier) }
        return DeviceHub(client: DeviceHubClient(baseURL: baseURL, identity: identity, tokens: tokens),
                         secrets: KeychainRelaySecretStore(bundleIdentifier: bundleIdentifier), deviceName: deviceName,
                         platform: platform, renewIdentity: { try DeviceIdentity.renew(bundleIdentifier: bundleIdentifier) })
    }

    /// Runs `load` off the main thread: the file Keychain and Secure Enclave
    /// calls behind an identity took 8-20 s on some Macs (H7).
    nonisolated static func loadIdentity(_ load: @escaping @Sendable () throws -> DeviceIdentity) async throws -> DeviceIdentity {
        try await Task.detached(priority: .userInitiated) { try load() }.value
    }

    public var identity: DeviceIdentity { client.identity }
    public var thisDevice: HubDevice? { devices.first { $0.id == identity.id } }
    /// The user's other devices.
    public var otherDevices: [HubDevice] { devices.filter { $0.id != identity.id } }

    /// What `viewer` may do on `host`'s screen; `ask` when no permission is stored.
    public func scope(host: String, viewer: String) -> DeviceScope {
        permissions[host]?.first { $0.viewerId == viewer }?.scope ?? .ask
    }

    // MARK: Lifecycle

    /// Signed in: registers this device, then keeps the socket open (each
    /// connect refetches everything, so nothing missed while away is lost).
    public func start() async {
        stopSocket()
        generation += 1
        let run = generation
        status = .starting
        do {
            do {
                _ = try await client.registerDevice(name: deviceName, platform: platform)
            } catch let error as DeviceHubError where (error.code == .deviceRemoved || error.code == .deviceKeyMismatch) && renewIdentity != nil {
                // This id was removed (or holds another key): register as a new device, once.
                guard run == generation, let renewIdentity else { return }
                let fresh: DeviceIdentity
                do { fresh = try await Self.loadIdentity(renewIdentity) } catch { throw DeviceHubError.identity("\(error)") }
                guard run == generation else { return }
                client.setIdentity(fresh)
                _ = try await client.registerDevice(name: deviceName, platform: platform)
            }
            guard run == generation else { return }
            status = .ready
        } catch {
            guard run == generation else { return }
            fail(error)
            status = .failed(lastError?.description ?? "\(error)")
            return
        }
        let socket = self.socket, hub = WeakHub(hub: self)
        socketTask = Task {
            await socket.run { event in
                await hub.hub?.handle(event)
            }
        }
    }

    /// Signed out: closes the socket and forgets the account and every record.
    public func stop() {
        generation += 1
        stopSocket()
        status = .idle
        connection = .disconnected
        me = nil
        devices = []
        permissions = [:]
        relays = []
        openedSecrets = [:]
        pendingRequests = []
        tickets = [:]
        audit = []
        lastError = nil
        pushCount = 0
        let client = self.client
        Task { await client.signOut() } // task-owner: a one-shot reset of the client's cached session
    }

    private func stopSocket() {
        socketTask?.cancel()
        socketTask = nil
    }

    // MARK: Pushes

    func handle(_ event: DeviceHubSocket.Event) async {
        switch event {
        case let .state(state):
            connection = state
            if state == .connected {
                // Back on the hub: whatever changed while away (a relaunched host's history) is read again.
                pushCount += 1
                await refreshAll()
            }
            if state == .removed { status = .failed("this device was removed") }
        case let .push(push):
            await handle(push)
        }
    }

    func handle(_ push: DeviceHubPush) async {
        if push != .pong { pushCount += 1 }
        switch push {
        case .devicesChanged:
            await refreshDevices()
        case let .permissionsChanged(host):
            await refreshPermissions(host: host ?? identity.id)
        case .relaysChanged:
            await refreshRelays()
        case let .sessionRequest(request):
            if !pendingRequests.contains(where: { $0.id == request.id }) { pendingRequests.append(request) }
            onSessionPush?(push)
        case let .sessionTicket(ticket):
            pendingRequests.removeAll { $0.id == ticket.sessionId }
            tickets[ticket.sessionId] = ticket
            onSessionPush?(push)
        case let .sessionDenied(id), let .sessionRevoked(id, _), let .sessionEnded(id, _):
            pendingRequests.removeAll { $0.id == id }
            tickets[id] = nil
            onSessionPush?(push)
        case .pong, .unknown:
            break
        }
    }

    // MARK: Refresh

    /// Everything again (a reconnect, Settings › Devices › Refresh): pushes have no
    /// backlog, so nothing read before is trusted. That includes this device's access
    /// to every other device, read from each host's permission list.
    public func refreshAll() async {
        await refreshMe()
        await refreshDevices()
        for host in permissionHosts { await refreshPermissions(host: host) }
        await refreshRelays()
    }

    /// The hosts whose permission lists a refresh reads: this device's own, then every
    /// other listed device that shares Mac Screen or whose list was read before.
    var permissionHosts: [String] {
        [identity.id] + devices.filter { $0.id != identity.id && ($0.macScreenShared || permissions[$0.id] != nil) }.map(\.id)
    }

    public func refreshMe() async {
        await load { try await $0.me() } into: { hub, value in hub.me = value }
    }

    public func refreshDevices() async {
        await load { try await $0.devices() } into: { hub, value in
            hub.devices = value
            hub.forgetPermissions(notListedIn: Set(value.map(\.id)))
        }
    }

    /// A device that left the list takes its permissions along, as host and as viewer.
    private func forgetPermissions(notListedIn listed: Set<String>) {
        guard !listed.isEmpty else { return }
        for host in permissions.keys where host != identity.id && !listed.contains(host) { permissions[host] = nil }
        for (host, list) in permissions {
            let kept = list.filter { listed.contains($0.viewerId) }
            if kept.count != list.count { permissions[host] = kept }
        }
    }

    public func refreshPermissions(host: String) async {
        await load { try await $0.permissions(host: host) } into: { hub, value in hub.permissions[host] = value }
    }

    /// Fetches the relays, then (off the main actor) opens and keeps each one's
    /// secret sealed to this device, drops the secrets of relays deleted
    /// elsewhere, and loads the secrets this device holds into memory.
    public func refreshRelays() async {
        let run = generation
        let listed: [HubRelay]
        do { listed = try await client.relays() } catch {
            guard run == generation else { return }
            fail(error)
            return
        }
        guard run == generation else { return }
        relays = listed
        // One this Mac just saved stays until a listing has shown it
        // (a listing fetched before the save would not have it yet).
        savedNotListed.subtract(listed.map(\.id))
        let opened = await vault.sync(listed: listed, keeping: savedNotListed, identity: identity)
        guard run == generation else { return }
        // A save or delete while the vault worked wins: keep the relays listed now, and
        // the ones just saved here with the secret their save put in memory.
        let listedNow = Set(relays.map(\.id))
        var held = opened.filter { listedNow.contains($0.key) }
        for id in savedNotListed { held[id] = openedSecrets[id] ?? opened[id] }
        openedSecrets = held
    }

    public func refreshAudit(limit: Int = 100) async {
        // This device's History: sessions where it is the viewer or the host.
        let device = identity.id
        await load { try await $0.audit(limit: limit, device: device) } into: { hub, value in hub.audit = value }
    }

    private func load<Value: Sendable>(_ fetch: @Sendable (DeviceHubClient) async throws -> Value,
                                       into apply: (DeviceHub, Value) -> Void) async {
        let run = generation
        do {
            let value = try await fetch(client)
            guard run == generation else { return }
            apply(self, value)
        } catch {
            guard run == generation else { return }
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        lastError = (error as? DeviceHubError) ?? .transport("\(error)")
    }

    // MARK: Intents

    /// Turns this device's Mac Screen sharing on or off.
    public func setMacScreenShared(_ shared: Bool) async throws {
        let device = try await perform { try await $0.setMacScreenShared(shared) }
        replace(device)
    }

    public func setPermission(host: String, viewer: String, scope: DeviceScope) async throws {
        _ = try await perform { try await $0.setPermission(host: host, viewer: viewer, scope: scope) }
        await refreshPermissions(host: host)
    }

    /// From this device as viewer: asks `host` for a session.
    public func requestSession(host: String, scope: SessionScope) async throws -> HubSession {
        try await perform { try await $0.requestSession(host: host, scope: scope) }
    }

    /// From this device as host: answers a request.
    public func decide(_ request: SessionRequest, decision: SessionDecision, scope: SessionScope) async throws {
        _ = try await perform { try await $0.decide(session: request.id, decision: decision, scope: scope) }
        pendingRequests.removeAll { $0.id == request.id }
        if decision == .always { await refreshPermissions(host: identity.id) }
    }

    /// Sign-out: the hub ends this device's sessions (`signed_out`) and closes its socket. Then ``stop()``.
    public func signOutDevice() async throws {
        try await perform { try await $0.signOutDevice() }
        tickets = [:]
    }

    public func endSession(_ id: String, reason: String) async throws {
        try await perform { try await $0.endSession(id, reason: reason) }
        tickets[id] = nil
    }

    /// Fresh cmux relay credentials for a session (paid plan; else empty).
    public func sessionICE(_ id: String) async throws -> [DeviceHubICEServer] {
        try await perform { try await $0.sessionICE(id) }
    }

    public func removeDevice(_ id: String) async throws {
        try await perform { try await $0.removeDevice(id) }
        devices.removeAll { $0.id == id }
        // The hub deleted every permission that names it; so does this device.
        permissions[id] = nil
        for (host, list) in permissions where list.contains(where: { $0.viewerId == id }) {
            permissions[host] = list.filter { $0.viewerId != id }
        }
    }

    public func rename(_ id: String, name: String) async throws {
        let device = try await perform { try await $0.renameDevice(id, name: name) }
        if id == identity.id { deviceName = name }
        replace(device)
    }

    /// Creates (no `id`) or replaces a relay. The secret is sealed to every
    /// device the hub lists now, this one included, and kept here too.
    @discardableResult
    public func saveRelay(id: String? = nil, name: String, urls: [String], secret: RelaySecret, enabled: Bool = true,
                          priority: Int = 0) async throws -> HubRelay {
        let id = id ?? UUID().uuidString.lowercased()
        savedNotListed.insert(id)
        let current = try await perform { try await $0.devices() }
        devices = current
        let sealed: [String: String]
        do { sealed = try RelaySealing.seal(secret, relayID: id, for: current) } catch {
            throw DeviceHubError.identity("sealing the relay secret: \(error)")
        }
        let update = RelayUpdate(id: id, name: name, urls: urls, authMode: secret.authMode, sealed: sealed, enabled: enabled, priority: priority)
        let relay = try await perform { try await $0.putRelay(update) }
        openedSecrets[id] = secret
        await vault.save(secret, relayID: id)
        await refreshRelays()
        return relay
    }

    public func deleteRelay(_ id: String) async throws {
        try await perform { try await $0.deleteRelay(id) }
        savedNotListed.remove(id)
        openedSecrets[id] = nil
        relays.removeAll { $0.id == id }
        await vault.remove(relayID: id)
    }

    /// The opened secret of a relay, when this device has it. From memory: views
    /// read it on every change, and the Keychain behind it can block for seconds.
    public func relaySecret(_ relayID: String) -> RelaySecret? {
        openedSecrets[relayID]
    }

    /// The ICE servers for a session: the ticket's cmux relay (if any), then
    /// the user's enabled relays this device can open, lowest priority first,
    /// shared-secret ones with credentials minted now.
    public func iceServers(for ticket: SessionTicket? = nil) -> [DeviceHubICEServer] {
        let name = thisDevice?.name ?? deviceName
        let mine = relays.filter(\.enabled).sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }.compactMap { relay in
            openedSecrets[relay.id].map { RelaySealing.iceServer(relay, secret: $0, deviceName: name, deviceID: identity.id, now: now()) }
        }
        return (ticket?.ice ?? []) + mine
    }

    private func replace(_ device: HubDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device } else { devices.append(device) }
    }

    @discardableResult
    private func perform<Value: Sendable>(_ body: @Sendable (DeviceHubClient) async throws -> Value) async throws -> Value {
        do { return try await body(client) } catch {
            fail(error)
            throw lastError ?? .transport("\(error)")
        }
    }
}

/// The socket task's handle on the hub, which must not keep it alive.
private struct WeakHub: Sendable {
    weak var hub: DeviceHub?
}
