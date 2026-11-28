import Foundation

/// The device-local relay choice restored at app startup.
public enum CmxIrohCustomRelaySelection: Equatable, Sendable {
    /// Use the managed relay policy.
    case managed

    /// Use the complete validated custom relay override.
    case custom(CmxIrohCustomRelayProfile)

    /// Keep managed relays disabled because a selected custom profile is unavailable.
    case customUnavailable
}

/// Persists a user-controlled relay override and its tokens in device-local secure storage.
public actor CmxIrohCustomRelayProfileStore {
    private struct RelayRecord: Codable {
        let url: String
        let authenticationToken: String?
    }

    private struct Record: Codable {
        let version: Int
        let relays: [RelayRecord]
    }

    private static let storageAccount = "active-custom-relay-profile"
    private static let selectionKey = "cmux.iroh.custom-relay-selection.v1"
    private static let customSelectionValue = "custom"
    private static let recordVersion = 1

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let selectionStore: any CmxIrohInstallStateStoring

    /// Creates a custom-relay profile store.
    ///
    /// - Parameters:
    ///   - secureStore: Device-local storage for relay URLs and secret tokens.
    ///   - selectionStore: Non-secret marker that prevents storage failures from
    ///     silently relaxing a custom override back to managed relays.
    public init(
        secureStore: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.iroh.custom-relays.v1"
        ),
        selectionStore: any CmxIrohInstallStateStoring = CmxIrohUserDefaultsInstallStateStore()
    ) {
        self.secureStore = secureStore
        self.selectionStore = selectionStore
    }

    /// Saves the complete active custom profile.
    ///
    /// - Parameter profile: A validated profile whose tokens must remain device-local.
    public func save(_ profile: CmxIrohCustomRelayProfile) async throws {
        let record = Record(
            version: Self.recordVersion,
            relays: profile.relays.map {
                RelayRecord(url: $0.url, authenticationToken: $0.authenticationToken)
            }
        )
        try await secureStore.write(
            JSONEncoder().encode(record),
            account: Self.storageAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        selectionStore.set(Self.customSelectionValue, forKey: Self.selectionKey)
    }

    /// Restores the active relay choice without weakening a custom override.
    ///
    /// If secure storage is locked, corrupt, or unavailable while the custom
    /// marker remains set, callers receive ``customUnavailable`` and can keep
    /// direct P2P enabled without enabling another relay provider.
    public func loadSelection() async -> CmxIrohCustomRelaySelection {
        guard selectionStore.string(forKey: Self.selectionKey)
            == Self.customSelectionValue else {
            return .managed
        }
        do {
            guard let profile = try await load() else {
                return .customUnavailable
            }
            return .custom(profile)
        } catch {
            return .customUnavailable
        }
    }

    /// Loads and revalidates the active custom profile.
    ///
    /// Corrupt records are deleted instead of being interpreted as relay policy.
    ///
    /// - Returns: The validated profile, or `nil` when none is installed.
    public func load() async throws -> CmxIrohCustomRelayProfile? {
        guard let data = try await secureStore.read(account: Self.storageAccount) else {
            return nil
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == Self.recordVersion,
              let profile = try? CmxIrohCustomRelayProfile(
                  relays: record.relays.map {
                      try CmxIrohCustomRelay(
                          url: $0.url,
                          authenticationToken: $0.authenticationToken
                      )
                  }
              ) else {
            try await secureStore.delete(account: Self.storageAccount)
            return nil
        }
        return profile
    }

    /// Removes the active custom profile and every stored relay token.
    public func clear() async throws {
        selectionStore.set(nil, forKey: Self.selectionKey)
        try await secureStore.delete(account: Self.storageAccount)
    }
}
