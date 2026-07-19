public import CMUXMobileCore
import CryptoKit
import Foundation

/// Validated device-local settings for one authenticated Mac.
public struct CmxIrohCustomPrivatePathConfiguration: Codable, Equatable, Sendable {
    public let macDeviceID: String
    public let macDisplayName: String
    public let addresses: [CmxIrohCustomPrivateAddress]
    public let isEnabled: Bool

    public init(
        macDeviceID: String,
        macDisplayName: String,
        addresses: [CmxIrohCustomPrivateAddress],
        isEnabled: Bool
    ) throws {
        let canonicalDeviceID = cmxCanonicalDeviceID(
            macDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let uuid = UUID(uuidString: canonicalDeviceID),
              uuid.uuidString.lowercased() == canonicalDeviceID,
              !addresses.isEmpty,
              addresses.count <= CmxIrohCustomPrivatePathDraft.maximumAddressCount,
              Set(addresses).count == addresses.count else {
            throw CmxIrohCustomPrivatePathStoreError.invalidConfiguration
        }
        let displayName = macDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard displayName.utf8.count <= 128,
              !displayName.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              }) else {
            throw CmxIrohCustomPrivatePathStoreError.invalidConfiguration
        }
        self.macDeviceID = canonicalDeviceID
        self.macDisplayName = displayName
        self.addresses = addresses
        self.isEnabled = isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            macDeviceID: container.decode(String.self, forKey: .macDeviceID),
            macDisplayName: container.decode(String.self, forKey: .macDisplayName),
            addresses: container.decode(
                [CmxIrohCustomPrivateAddress].self,
                forKey: .addresses
            ),
            isEnabled: container.decode(Bool.self, forKey: .isEnabled)
        )
    }
}

/// Credential-free state used to compose private-path authorization.
public struct CmxIrohCustomPrivatePathSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let configurations: [CmxIrohCustomPrivatePathConfiguration]
    public let activeNetworkProfiles: Set<CmxIrohNetworkProfileKey>

    public init(
        generation: UInt64,
        configurations: [CmxIrohCustomPrivatePathConfiguration],
        activeNetworkProfiles: Set<CmxIrohNetworkProfileKey>
    ) {
        self.generation = generation
        self.configurations = configurations
        self.activeNetworkProfiles = activeNetworkProfiles
    }

    public static let unavailable = CmxIrohCustomPrivatePathSnapshot(
        generation: 1,
        configurations: [],
        activeNetworkProfiles: []
    )
}

/// One locally configured address plus its opaque active-profile authority.
public struct CmxIrohCustomPrivatePathBootstrap: Equatable, Sendable {
    public let address: CmxIrohCustomPrivateAddress
    public let networkProfile: CmxIrohNetworkProfileKey

    public init(
        address: CmxIrohCustomPrivateAddress,
        networkProfile: CmxIrohNetworkProfileKey
    ) throws {
        guard networkProfile.source == .customVPN else {
            throw CmxIrohCustomPrivatePathStoreError.invalidConfiguration
        }
        self.address = address
        self.networkProfile = networkProfile
    }
}

/// Device-only, account-isolated persistence for explicit private addresses.
///
/// Addresses are non-secret routing preferences, so this store deliberately
/// uses app-local defaults instead of Keychain. This keeps the transport's
/// Keychain-stall degradation unchanged while preventing account or broker sync.
public actor CmxIrohCustomPrivatePathStore {
    struct Record: Codable {
        let version: Int
        let generation: UInt64
        let configurations: [CmxIrohCustomPrivatePathConfiguration]
    }

    struct State {
        var generation: UInt64
        var configurations: [CmxIrohCustomPrivatePathConfiguration]
    }

    public static let maximumConfigurationCount = 64
    private static let recordVersion = 1
    private static let maximumEncodedByteCount = 64 * 1_024

    private let store: any CmxIrohInstallStateStoring
    private var states: [String: State] = [:]

    public init(
        store: any CmxIrohInstallStateStoring = CmxIrohUserDefaultsInstallStateStore()
    ) {
        self.store = store
    }

    public func snapshot(accountID: String) throws -> CmxIrohCustomPrivatePathSnapshot {
        let scope = try storageScope(accountID)
        let state = try state(for: scope)
        return try snapshot(state: state, scope: scope)
    }

    /// Loads current preferences, failing closed without disabling Iroh when
    /// local settings are malformed or unavailable.
    public func availableSnapshot(
        accountID: String
    ) -> CmxIrohCustomPrivatePathSnapshot {
        (try? snapshot(accountID: accountID)) ?? .unavailable
    }

    public func upsert(
        _ draft: CmxIrohCustomPrivatePathDraft,
        accountID: String
    ) throws -> CmxIrohCustomPrivatePathSnapshot {
        let configuration = try Self.validatedConfiguration(draft)
        let scope = try storageScope(accountID)
        var state = try state(for: scope)
        if let index = state.configurations.firstIndex(where: {
            $0.macDeviceID == configuration.macDeviceID
        }) {
            state.configurations[index] = configuration
        } else {
            guard state.configurations.count < Self.maximumConfigurationCount else {
                throw CmxIrohCustomPrivatePathStoreError.tooManyConfigurations
            }
            state.configurations.append(configuration)
        }
        state.configurations.sort { $0.macDeviceID < $1.macDeviceID }
        state.generation = nextGeneration(state.generation)
        try persist(state, scope: scope)
        states[scope] = state
        return try snapshot(state: state, scope: scope)
    }

    public func remove(
        macDeviceID: String,
        accountID: String
    ) throws -> CmxIrohCustomPrivatePathSnapshot {
        let canonical = cmxCanonicalDeviceID(
            macDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let scope = try storageScope(accountID)
        var state = try state(for: scope)
        guard state.configurations.contains(where: { $0.macDeviceID == canonical }) else {
            throw CmxIrohCustomPrivatePathStoreError.missingConfiguration
        }
        state.configurations.removeAll { $0.macDeviceID == canonical }
        state.generation = nextGeneration(state.generation)
        try persist(state, scope: scope)
        states[scope] = state
        return try snapshot(state: state, scope: scope)
    }

    /// Returns paths only for the exact expected Mac and current account.
    public func enabledPaths(
        forMacDeviceID macDeviceID: String,
        accountID: String
    ) -> [CmxIrohCustomPrivatePathBootstrap] {
        guard let scope = try? storageScope(accountID),
              let state = try? state(for: scope),
              let configuration = state.configurations.first(where: {
                  $0.macDeviceID == cmxCanonicalDeviceID(macDeviceID)
              }),
              configuration.isEnabled,
              let profile = try? profile(
                  accountScope: scope,
                  macDeviceID: configuration.macDeviceID
              ) else { return [] }
        return configuration.addresses.compactMap {
            try? CmxIrohCustomPrivatePathBootstrap(
                address: $0,
                networkProfile: profile
            )
        }
    }

    private static func validatedConfiguration(
        _ draft: CmxIrohCustomPrivatePathDraft
    ) throws -> CmxIrohCustomPrivatePathConfiguration {
        var addresses: [CmxIrohCustomPrivateAddress] = []
        for value in draft.addresses {
            let address = try CmxIrohCustomPrivateAddress(value)
            if !addresses.contains(address) { addresses.append(address) }
        }
        return try CmxIrohCustomPrivatePathConfiguration(
            macDeviceID: draft.macDeviceID,
            macDisplayName: draft.macDisplayName,
            addresses: addresses,
            isEnabled: draft.isEnabled
        )
    }

    private func storageScope(_ accountID: String) throws -> String {
        try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-private-paths"
        )
    }

    private func state(for scope: String) throws -> State {
        if let state = states[scope] { return state }
        let loaded: State
        if let encoded = store.string(forKey: scope) {
            guard let data = Data(base64Encoded: encoded),
                  data.count <= Self.maximumEncodedByteCount,
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.version == Self.recordVersion,
                  record.generation > 0,
                  record.configurations.count <= Self.maximumConfigurationCount,
                  Set(record.configurations.map(\.macDeviceID)).count
                    == record.configurations.count else {
                throw CmxIrohCustomPrivatePathStoreError.invalidStoredConfiguration
            }
            loaded = State(
                generation: record.generation,
                configurations: record.configurations.sorted {
                    $0.macDeviceID < $1.macDeviceID
                }
            )
        } else {
            loaded = State(generation: 1, configurations: [])
        }
        states[scope] = loaded
        return loaded
    }

    private func persist(_ state: State, scope: String) throws {
        let data = try JSONEncoder().encode(Record(
            version: Self.recordVersion,
            generation: state.generation,
            configurations: state.configurations
        ))
        guard data.count <= Self.maximumEncodedByteCount else {
            throw CmxIrohCustomPrivatePathStoreError.invalidConfiguration
        }
        store.set(data.base64EncodedString(), forKey: scope)
    }

    private func snapshot(
        state: State,
        scope: String
    ) throws -> CmxIrohCustomPrivatePathSnapshot {
        var profiles: Set<CmxIrohNetworkProfileKey> = []
        for configuration in state.configurations
        where configuration.isEnabled && !configuration.addresses.isEmpty {
            profiles.insert(try profile(
                accountScope: scope,
                macDeviceID: configuration.macDeviceID
            ))
        }
        return CmxIrohCustomPrivatePathSnapshot(
            generation: state.generation,
            configurations: state.configurations,
            activeNetworkProfiles: profiles
        )
    }

    private func profile(
        accountScope: String,
        macDeviceID: String
    ) throws -> CmxIrohNetworkProfileKey {
        let digest = SHA256.hash(
            data: Data("custom-private-path-v1\0\(accountScope)\0\(macDeviceID)".utf8)
        )
        var encoded = [UInt8]()
        encoded.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            encoded.append(Self.hexDigits[Int(byte >> 4)])
            encoded.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        return try CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: String(decoding: encoded, as: UTF8.self)
        )
    }

    private func nextGeneration(_ current: UInt64) -> UInt64 {
        current == .max ? 1 : current + 1
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
}

public enum CmxIrohCustomPrivatePathStoreError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidStoredConfiguration
    case tooManyConfigurations
    case missingConfiguration
}
