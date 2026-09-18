import CMUXMobileCore
import CmuxAuthRuntime
import CmuxV3Native
import CmuxV3Transport
import CryptoKit
import Foundation
import Security

/// Staged v3 host owner. It is opt-in while the client and relay rollout are
/// being validated. The endpoint is recreated for every authenticated team,
/// and the native endpoint is the admission boundary for every accepted stream.
@MainActor
final class MobileHostV3Runtime: MobileHostPairingRuntime {
    static let shared = MobileHostV3Runtime()

    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_V3_HOST"] == "1"
            || UserDefaults.standard.bool(forKey: "cmux.transport-v3.host-enabled")
    }

    private var auth: AuthCoordinator?
    private var authTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    private var acceptOperation: CmuxV3Native.Operation?
    private var endpoint: NativeEndpoint?
    private var scope: AuthenticatedTeamScope?
    private var desiredScope: AuthenticatedTeamScope?
    private var generation = UUID()
    private var continuations: [UUID: AsyncStream<MobileHostListenerState>.Continuation] = [:]
    private(set) var listenerState = MobileHostListenerState() {
        didSet {
            guard listenerState != oldValue else { return }
            for continuation in continuations.values { continuation.yield(listenerState) }
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
    }

    var isNetworkingAllowed: Bool {
        isEnabled && MobileHostService.isListeningEnabled && !MobileRemoteControlPolicy.isDisabled
    }

    func configure(auth: AuthCoordinator) {
        self.auth = auth
        authTask?.cancel()
        authTask = Task { @MainActor [weak self, weak auth] in
            guard let self, let auth else { return }
            await auth.awaitBootstrapped()
            for await next in auth.authenticatedTeamScopes() {
                guard !Task.isCancelled else { return }
                await self.apply(next, auth: auth)
            }
        }
    }

    func applyManagedNetworkingPolicy() async {
        await reconcile()
    }

    func prepareForStop() {
        generation = UUID()
        desiredScope = nil
        activationTask?.cancel()
        activationTask = nil
        acceptOperation?.cancel()
        acceptOperation = nil
        acceptTask?.cancel()
        acceptTask = nil
        endpoint?.close()
        endpoint = nil
        scope = nil
        listenerState = MobileHostListenerState()
        MobileHostPublicStatusCache.updateV3(peerID: nil)
        MobileHostPublicStatusCache.updateV2DeviceID(nil)
    }

    func stopHost() async {
        prepareForStop()
    }

    func foreground() async {
        await reconcile()
    }

    func listenerStateUpdates() -> AsyncStream<MobileHostListenerState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(listenerState)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func apply(_ next: AuthenticatedTeamScope?, auth: AuthCoordinator) async {
        guard desiredScope != next else { return }
        desiredScope = next
        activationTask?.cancel()
        activationTask = nil
        acceptOperation?.cancel()
        acceptOperation = nil
        acceptTask?.cancel()
        acceptTask = nil
        endpoint?.close()
        endpoint = nil
        scope = nil
        MobileHostPublicStatusCache.updateV3(peerID: nil)
        MobileHostPublicStatusCache.updateV2DeviceID(nil)
        guard let next else {
            listenerState = MobileHostListenerState()
            return
        }
        await reconcile(scope: next, auth: auth)
    }

    private func reconcile() async {
        guard let auth, let desiredScope else {
            if !isNetworkingAllowed { prepareForStop() }
            return
        }
        await reconcile(scope: desiredScope, auth: auth)
    }

    private func reconcile(scope next: AuthenticatedTeamScope, auth: AuthCoordinator) async {
        guard isNetworkingAllowed else {
            prepareForStop()
            return
        }
        guard endpoint == nil else { return }
        let token = generation
        listenerState = MobileHostListenerState(phase: .starting)
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    try await self.provision(next, auth: auth, generation: token)
                    return
                } catch {
                    self.listenerState = MobileHostListenerState(
                        phase: .retrying,
                        failureDescription: String(describing: error)
                    )
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    private func provision(
        _ next: AuthenticatedTeamScope,
        auth: AuthCoordinator,
        generation token: UUID
    ) async throws {
        guard generation == token, desiredScope == next, isNetworkingAllowed else {
            throw Error.stale
        }
        let configuration = try V3HostConfiguration(environment: ProcessInfo.processInfo.environment)
        let identity = try MobileHostV3IdentityStore(service: configuration.identityService)
        let seed = try identity.seed()
        let deviceID = try identity.deviceID()
        let endpoint = try await NativeEndpoint.create(
            seed: seed,
            team: next.teamID,
            authorityKeys: configuration.authorityKeys
        )
        let bound = try await endpoint.listen(
            address: "/ip4/0.0.0.0/udp/0/quic-v1",
            operation: CmuxV3Native.Operation()
        )
        let key = try CmxV3SigningKey(rawRepresentation: seed)
        let grantConfiguration = try CmxV3HTTPGrantProvider.Configuration(
            origin: configuration.controlOrigin,
            audience: configuration.audience,
            team: next.teamID,
            deviceID: deviceID.uuidString,
            signingKey: key,
            accessToken: { try await auth.accessToken() },
            userID: { try await auth.authenticatedSessionSnapshot().accountID }
        )
        let grants = CmxV3HTTPGrantProvider(configuration: grantConfiguration)
        let addresses = try await endpoint.addresses(operation: CmuxV3Native.Operation())
            .filter { !$0.isEmpty && !$0.contains("/p2p/") }
            .map { "\($0)/p2p/\(endpoint.peerId())" }
        try await grants.enroll(peerID: endpoint.peerId(), deviceID: deviceID, addresses: addresses)
        guard generation == token, desiredScope == next, isNetworkingAllowed else {
            endpoint.close()
            throw Error.stale
        }
        self.endpoint = endpoint
        self.scope = next
        MobileHostPublicStatusCache.updateV3(peerID: endpoint.peerId(), addresses: addresses)
        MobileHostPublicStatusCache.updateV2DeviceID(deviceID.uuidString)
        listenerState = MobileHostListenerState(
            phase: .ready,
            boundPort: Self.port(in: bound),
            preferredPort: MobileHostService.configuredPort(),
            localSocketAddresses: addresses,
            hasAuthenticatedRegistration: true
        )
        let operation = CmuxV3Native.Operation()
        acceptOperation = operation
        acceptTask = Task { @MainActor [weak self, weak endpoint] in
            guard let self, let endpoint else { return }
            await self.acceptLoop(endpoint: endpoint, operation: operation, deviceID: deviceID, generation: token)
        }
    }

    private func acceptLoop(
        endpoint: NativeEndpoint,
        operation: CmuxV3Native.Operation,
        deviceID: UUID,
        generation token: UUID
    ) async {
        while !Task.isCancelled, generation == token, desiredScope == scope, isNetworkingAllowed {
            do {
                let accepted = try await endpoint.accept(operation: operation)
                guard accepted.lane.kind == 0 else {
                    // Event and application lanes are deliberately rejected
                    // until their host-side handlers are migrated to v3.
                    accepted.stream.close()
                    continue
                }
                let transport = V3ByteTransport(stream: accepted.stream)
                let peer = CmxV3AdmittedPeer(peerID: accepted.peerId)
                Task {
                    _ = await MobileHostService.acceptTransport(
                        transport,
                        authorization: .v3Admission(peer),
                        hostDeviceID: deviceID.uuidString,
                        isCurrent: { [weak self] in
                            guard let self else { return false }
                            return await MainActor.run {
                                self.generation == token && self.scope != nil && self.isNetworkingAllowed
                            }
                        }
                    )
                }
            } catch NativeError.Cancelled, NativeError.Closed {
                return
            } catch {
                guard !Task.isCancelled else { return }
                listenerState = MobileHostListenerState(
                    phase: .retrying,
                    boundPort: listenerState.boundPort,
                    preferredPort: listenerState.preferredPort,
                    localSocketAddresses: listenerState.localSocketAddresses,
                    failureDescription: String(describing: error),
                    hasAuthenticatedRegistration: true
                )
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func port(in address: String) -> Int? {
        let components = address.split(separator: "/")
        guard let index = components.firstIndex(of: "udp"), components.indices.contains(index + 1) else {
            return nil
        }
        return Int(components[index + 1])
    }

    private enum Error: Swift.Error, Sendable {
        case stale
    }
}

private struct V3HostConfiguration: Sendable {
    let controlOrigin: URL
    let audience: String
    let authorityKeys: [String: Data]
    let identityService: String

    init(environment: [String: String]) throws {
        guard let rawOrigin = environment["CMUX_V3_CONTROL_ORIGIN"], let origin = URL(string: rawOrigin),
              let rawKeys = environment["CMUX_V3_AUTHORITY_KEYS"],
              let keyData = rawKeys.data(using: .utf8),
              let encoded = try? JSONDecoder().decode([String: String].self, from: keyData),
              !encoded.isEmpty else { throw Error.invalidConfiguration }
        let keys = encoded.compactMapValues(V3HostConfiguration.decodeHex)
        guard keys.count == encoded.count, keys.values.allSatisfy({ $0.count == 32 }) else {
            throw Error.invalidConfiguration
        }
        guard origin.host != nil,
              origin.user == nil,
              origin.password == nil,
              origin.query == nil,
              origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/",
              origin.scheme?.lowercased() == "https" || origin.host == "127.0.0.1" || origin.host == "localhost"
        else { throw Error.invalidConfiguration }
        controlOrigin = origin
        audience = environment["CMUX_V3_AUDIENCE"] ?? "cmux-v3-production"
        authorityKeys = keys
        identityService = environment["CMUX_V3_IDENTITY_SERVICE"] ?? "dev.cmux.transport-v3.host"
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count == 64 else { return nil }
        var data = Data(capacity: 32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    enum Error: Swift.Error, Sendable {
        case invalidConfiguration
    }
}

private struct MobileHostV3IdentityStore: Sendable {
    let service: String

    func seed() throws -> Data {
        if let existing = read(account: "seed"), existing.count == 32 { return existing }
        var value = Data(repeating: 0, count: 32)
        let status = value.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress)
        }
        guard status == errSecSuccess else {
            throw Error.keychain
        }
        return try insert(value, account: "seed")
    }

    func deviceID() throws -> UUID {
        if let existing = read(account: "device-id"), let value = String(data: existing, encoding: .utf8), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        _ = try insert(Data(id.uuidString.utf8), account: "device-id")
        return id
    }

    private func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func insert(_ data: Data, account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = read(account: account) { return existing }
        guard status == errSecSuccess else { throw Error.keychain }
        return data
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    enum Error: Swift.Error, Sendable {
        case keychain
    }
}
