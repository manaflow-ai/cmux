import Foundation

/// Whether a Cloud machine keeps its image's coding-agent versions or updates
/// them, the wire value of `agentUpdates` (`web/services/vms/agentUpdates.ts`).
/// With `.latest` the machine installs npm's newest Claude Code, Codex,
/// OpenCode, and Pi when you connect, at most once a day.
public enum CloudAgentUpdates: String, Codable, CaseIterable, Sendable {
    /// The versions the machine's image baked (the default).
    case image
    /// npm's `latest` release, checked on attach at most once a day.
    case latest

    /// Decodes a wire value; nil for a missing field (an older server) or an
    /// unknown value.
    public init?(wireValue: Any?) {
        guard let raw = wireValue as? String else { return nil }
        self.init(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public init(keepsAgentsUpdated: Bool) {
        self = keepsAgentsUpdated ? .latest : .image
    }

    public var keepsAgentsUpdated: Bool { self == .latest }

    /// The note shown next to the choice when the machine's network policy
    /// would block the update. Nil when there is nothing to warn about.
    public func networkNote(for policy: CloudNetworkPolicy) -> String? {
        guard self == .latest, !policy.allowsNpmRegistry else { return nil }
        return Self.npmBlockedNote
    }

    public static var npmBlockedNote: String {
        String(
            localized: "cloud.agentUpdates.npmBlocked",
            defaultValue: "Updates need npm registry access. Add the npm preset or they will fail."
        )
    }
}

extension CloudNetworkPolicy {
    /// The preset (`NETWORK_POLICY_PRESETS` id) that allows the npm registry.
    public static let npmPresetID = "npm"
    /// The host agent updates download from.
    public static let npmRegistryDomain = "registry.npmjs.org"

    /// Whether the machine can reach the npm registry that agent updates use:
    /// always with full internet, never with none, and in allowlist mode only
    /// through the npm preset or the registry's domain.
    public var allowsNpmRegistry: Bool {
        switch mode {
        case .full: return true
        case .none: return false
        case .allowlist:
            return presets.contains(Self.npmPresetID) || domains.contains(Self.npmRegistryDomain)
        }
    }
}
