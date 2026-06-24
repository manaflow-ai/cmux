public import CMUXAgentLaunch
import Foundation

/// A vault-registered (non-built-in) agent identified for the session index, carrying
/// its id and optional display/icon metadata.
public struct RegisteredSessionAgent: Hashable, Sendable {
    public let id: String
    public let name: String?
    public let iconAssetName: String?

    public init(id: String, name: String? = nil, iconAssetName: String? = nil) {
        self.id = id
        self.name = Self.normalizedOptional(name)
        self.iconAssetName = Self.normalizedOptional(iconAssetName)
    }

    public init(registration: CmuxVaultAgentRegistration) {
        self.init(id: registration.id, name: registration.name, iconAssetName: registration.iconAssetName)
    }

    public var displayName: String {
        if let name {
            return name
        }
        if id == "pi" {
            return "Pi"
        }
        return id
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
