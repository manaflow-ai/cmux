import Foundation

/// Persists unsent composer text by acpmux session.
public protocol AgentPaneDraftStoring: Sendable {
    /// Returns the unsent composer text for `sessionId`, or nil when none is saved.
    func draft(for sessionId: String) async -> String?

    /// Stores `text` for `sessionId`; an empty text removes the saved draft.
    func setDraft(_ text: String, for sessionId: String) async
}

/// Stores agent composer drafts in app-owned defaults so WebKit's private page stores can stay ephemeral.
public actor UserDefaultsAgentPaneDraftStore: AgentPaneDraftStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String

    /// Creates a draft store backed by `defaults`.
    ///
    /// - Parameters:
    ///   - defaults: The defaults suite that owns the drafts.
    ///   - keyPrefix: A namespace for the stored session keys.
    public init(defaults: UserDefaults, keyPrefix: String = "cmux.next.agent.composer-draft.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    /// Creates a draft store backed by the app's standard defaults suite.
    public init() {
        self.init(defaults: UserDefaults.standard)
    }

    /// Returns the stored draft for `sessionId`.
    public func draft(for sessionId: String) -> String? {
        guard let key = key(for: sessionId) else { return nil }
        return defaults.string(forKey: key)
    }

    /// Stores or removes the draft for `sessionId`.
    public func setDraft(_ text: String, for sessionId: String) {
        guard let key = key(for: sessionId) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(text, forKey: key)
        }
    }

    private func key(for sessionId: String) -> String? {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return keyPrefix + sessionId
    }
}
