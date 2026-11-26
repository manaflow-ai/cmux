import Foundation

/// Whether a Cloud machine keeps its image's coding-agent versions or updates
/// them, the wire value of `agentUpdates` (`web/services/vms/agentUpdates.ts`).
/// With `.latest` the machine installs the newest Claude Code, Codex,
/// OpenCode, Pi, and agent-browser releases (each tool's own GitHub release,
/// public for 3 days) when you connect, at most once a day.
public enum CloudAgentUpdates: String, Codable, CaseIterable, Sendable {
    /// The versions the machine's image baked (the default).
    case image
    /// Each agent's newest eligible release, checked on attach at most once a day.
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
    /// would block the update: the catalog's update hosts the policy does not
    /// allow. Nil when there is nothing to warn about.
    public func networkNote(for policy: CloudNetworkPolicy, catalog: CloudNetworkPresetCatalog) -> String? {
        guard self == .latest else { return nil }
        let blocked = catalog.agentUpdateDomains.filter { !policy.allows($0, catalog: catalog) }
        guard !blocked.isEmpty else { return nil }
        return Self.blockedNote(domains: blocked)
    }

    public static func blockedNote(domains: [String]) -> String {
        let format = String(
            localized: "cloud.agentUpdates.hostsBlocked",
            defaultValue: "Agent updates need %@, which this network policy blocks. Allow it or updates will fail."
        )
        return String(format: format, domains.joined(separator: ", "))
    }
}

extension CloudNetworkPolicy {
    /// Whether the policy lets the machine reach `domain` over HTTPS: always
    /// with full internet, and otherwise when cmux always allows it or, in
    /// allowlist mode, when it is listed or in a selected preset.
    public func allows(_ domain: String, catalog: CloudNetworkPresetCatalog) -> Bool {
        if mode == .full || catalog.requiredDomains.contains(domain) { return true }
        guard mode == .allowlist else { return false }
        return domains.contains(domain)
            || catalog.presets.contains { presets.contains($0.id) && $0.domains.contains(domain) }
    }
}
