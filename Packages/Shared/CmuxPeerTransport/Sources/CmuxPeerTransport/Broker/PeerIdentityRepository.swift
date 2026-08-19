public import Foundation
import CryptoKit

/// Non-secret installation state used to detect reinstall and account changes.
public protocol PeerInstallStateStoring: Sendable {
    /// Returns the value for a repository-owned state key.
    func string(forKey key: String) -> String?

    /// Sets or clears the value for a repository-owned state key.
    func set(_ value: String?, forKey key: String)
}

/// `UserDefaults` installation marker storage for production composition.
public final class PeerUserDefaultsInstallStateStore: PeerInstallStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Reconciles stable endpoint identity with reinstall and account-switch policy.
///
/// Storage contract (identical to the previous transport, so existing installs
/// keep their identity across the engine swap):
/// - Keychain account = SHA-256 hex of `cmux/iroh/identity-scope/v1\0<account>\0<appInstance>`
/// - Record = 1 version byte (1) + big-endian UInt32 generation + 32 secret bytes
/// - Install marker `UserDefaults` key `cmux.iroh.identity.install-marker.v1`
/// - Active scope `UserDefaults` key `cmux.iroh.identity.active-scope.v1`
///
/// A missing install marker removes Keychain material that survived an app
/// uninstall. Changing account scope removes the prior account key before
/// creating a new EndpointID. A store read of `.unavailable` propagates as
/// ``PeerIdentityError/storeUnavailable(status:)`` and never mints a
/// replacement identity.
public actor PeerIdentityRepository {
    private static let installMarkerKey = "cmux.iroh.identity.install-marker.v1"
    private static let activeScopeKey = "cmux.iroh.identity.active-scope.v1"
    private static let recordVersion: UInt8 = 1
    private static let maximumQueuedOperations = 64

    private let secureStore: any PeerSecureBlobStoring
    private let installState: any PeerInstallStateStoring
    private let randomBytes: @Sendable () throws -> Data
    private let marker: @Sendable () -> String
    private var operationIsActive = false
    private var operationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var operationWaiterOrder: [UUID] = []

    /// Creates an identity repository with injectable persistence and entropy.
    public init(
        secureStore: any PeerSecureBlobStoring = PeerIdentityStore(),
        installState: any PeerInstallStateStoring = PeerUserDefaultsInstallStateStore(),
        randomBytes: @escaping @Sendable () throws -> Data = {
            try PeerIdentityStore.randomSecretBytes()
        },
        marker: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.secureStore = secureStore
        self.installState = installState
        self.randomBytes = randomBytes
        self.marker = marker
    }

    /// Returns stable material for the exact account and app instance.
    public func identity(
        accountID: String,
        appInstanceID: String
    ) async throws -> PeerEndpointIdentity {
        try await beginOperation()
        defer { endOperation() }
        try Task.checkCancellation()
        let scope = try await prepareScope(accountID: accountID, appInstanceID: appInstanceID)
        switch await secureStore.read(account: scope) {
        case let .found(encoded):
            return try Self.decode(encoded)
        case .absent:
            return try await create(scope: scope, generation: 1)
        case let .unavailable(status):
            throw PeerIdentityError.storeUnavailable(status: status)
        }
    }

    /// Replaces the active account key and increments its identity generation.
    public func rotate(
        accountID: String,
        appInstanceID: String
    ) async throws -> PeerEndpointIdentity {
        try await beginOperation()
        defer { endOperation() }
        try Task.checkCancellation()
        let scope = try await prepareScope(accountID: accountID, appInstanceID: appInstanceID)
        let generation: Int
        switch await secureStore.read(account: scope) {
        case let .found(encoded):
            let current = try Self.decode(encoded)
            guard current.generation < Int(Int32.max) else {
                throw PeerIdentityError.invalidGeneration
            }
            generation = current.generation + 1
        case .absent:
            generation = 1
        case let .unavailable(status):
            throw PeerIdentityError.storeUnavailable(status: status)
        }
        return try await create(scope: scope, generation: generation)
    }

    /// Removes all endpoint identity when signing out or locally revoking it.
    public func deactivate() async throws {
        try await beginOperation()
        defer { endOperation() }
        try Task.checkCancellation()
        try await secureStore.deleteAll()
        installState.set(nil, forKey: Self.activeScopeKey)
    }

    private func beginOperation() async throws {
        guard operationIsActive else {
            operationIsActive = true
            return
        }
        guard operationWaiterOrder.count < Self.maximumQueuedOperations else {
            throw PeerIdentityError.operationLimitExceeded
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                operationWaiters[id] = continuation
                operationWaiterOrder.append(id)
            }
        } onCancel: {
            Task { await self.cancelOperationWaiter(id) }
        }
    }

    private func endOperation() {
        guard let id = operationWaiterOrder.first else {
            operationIsActive = false
            return
        }
        operationWaiterOrder.removeFirst()
        operationWaiters.removeValue(forKey: id)?.resume()
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let continuation = operationWaiters.removeValue(forKey: id) else {
            return
        }
        operationWaiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    private func prepareScope(accountID: String, appInstanceID: String) async throws -> String {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 1_024,
              !appInstanceID.isEmpty,
              appInstanceID.utf8.count <= 256 else {
            throw PeerIdentityError.invalidScope
        }
        var clearedSecureStore = false
        if installState.string(forKey: Self.installMarkerKey) == nil {
            try await secureStore.deleteAll()
            clearedSecureStore = true
            installState.set(nil, forKey: Self.activeScopeKey)
            installState.set(marker(), forKey: Self.installMarkerKey)
        }
        let scope = Self.scope(accountID: accountID, appInstanceID: appInstanceID)
        if installState.string(forKey: Self.activeScopeKey) != scope {
            if !clearedSecureStore {
                try await secureStore.deleteAll()
            }
            installState.set(scope, forKey: Self.activeScopeKey)
        }
        return scope
    }

    private func create(scope: String, generation: Int) async throws -> PeerEndpointIdentity {
        let secretKey = try PeerSecretKey(bytes: randomBytes())
        let material = try PeerEndpointIdentity(secretKey: secretKey, generation: generation)
        try await secureStore.write(Self.encode(material), account: scope)
        return material
    }

    private static func scope(accountID: String, appInstanceID: String) -> String {
        let transcript = Data(
            "cmux/iroh/identity-scope/v1\0\(accountID)\0\(appInstanceID)".utf8
        )
        return PeerBrokerWire.hex(Data(SHA256.hash(data: transcript)))
    }

    private static func encode(_ material: PeerEndpointIdentity) -> Data {
        var bytes = [recordVersion]
        let generation = UInt32(material.generation)
        bytes.append(UInt8((generation >> 24) & 0xff))
        bytes.append(UInt8((generation >> 16) & 0xff))
        bytes.append(UInt8((generation >> 8) & 0xff))
        bytes.append(UInt8(generation & 0xff))
        bytes.append(contentsOf: material.secretKey.bytes)
        return Data(bytes)
    }

    private static func decode(_ data: Data) throws -> PeerEndpointIdentity {
        let bytes = [UInt8](data)
        guard bytes.count == 37, bytes[0] == recordVersion else {
            throw PeerIdentityError.corruptRecord
        }
        let generation = UInt32(bytes[1]) << 24
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 8
            | UInt32(bytes[4])
        guard generation > 0, generation <= UInt32(Int32.max) else {
            throw PeerIdentityError.corruptRecord
        }
        let secretKey = try PeerSecretKey(bytes: Data(bytes[5...]))
        return try PeerEndpointIdentity(
            secretKey: secretKey,
            generation: Int(generation)
        )
    }
}
