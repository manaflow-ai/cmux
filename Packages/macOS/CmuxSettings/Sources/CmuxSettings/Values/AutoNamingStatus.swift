import Foundation

/// The outcome of the most recent auto-naming attempt, surfaced in Settings
/// (never in workspace/tab titles). A failed pass leaves names untouched; this
/// is the only place the user learns the naming agent couldn't produce a title.
public struct AutoNamingStatus: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable {
        /// The summarizer ran but failed — most often rate-limited, out of
        /// tokens/quota, signed out, or timed out.
        case failed
        /// The chosen override agent's binary isn't installed, so naming fell
        /// back to each session's own agent.
        case notInstalled = "not_installed"
        /// cmux could not probe the app for live auto-naming settings.
        case probeFailed = "probe_failed"
        /// cmux could not read or understand the agent transcript.
        case extractionFailed = "extraction_failed"
        /// cmux generated a title but the app rejected or failed the apply.
        case applyFailed = "apply_failed"
    }

    public let category: Category
    /// Agent slug the status refers to (see ``AutoNamingAgentCatalog``).
    public let agent: String
    /// Epoch seconds when the status was recorded.
    public let at: TimeInterval

    public init(category: Category, agent: String, at: TimeInterval) {
        self.category = category
        self.agent = agent
        self.at = at
    }
}

/// Reads/writes the last auto-naming status in `UserDefaults`. The app's socket
/// handler records it when a naming pass reports a problem; the Settings UI
/// reads it to show a single status line. Persisted as a JSON string under one
/// key so it survives relaunch and is trivially observable.
/// lint:allow namespace-type — stateless accessor; the `UserDefaults` store is injected per call via the `in:` parameter (used by tests), so there is no hidden global state to model as an instance.
public enum AutoNamingStatusStore {
    public static let userDefaultsKey = "autoNamingLastStatus"

    public static func record(_ status: AutoNamingStatus, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(status),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: userDefaultsKey)
    }

    /// Records a status from raw socket fields. Unknown categories are ignored
    /// so a future CLI can add categories without corrupting older apps.
    public static func record(
        rawCategory: String,
        agent: String,
        at: TimeInterval,
        in defaults: UserDefaults = .standard
    ) {
        guard let category = AutoNamingStatus.Category(rawValue: rawCategory) else { return }
        record(AutoNamingStatus(category: category, agent: agent, at: at), in: defaults)
    }

    public static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    public static func current(in defaults: UserDefaults = .standard) -> AutoNamingStatus? {
        guard let json = defaults.string(forKey: userDefaultsKey),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AutoNamingStatus.self, from: data)
    }
}
