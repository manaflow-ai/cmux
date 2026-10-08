public import Foundation

/// Persists unsent composer text by acpmux session.
public protocol AgentPaneDraftStoring: Sendable {
    /// Returns the unsent composer text for `sessionId`, or nil when none is saved.
    func draft(for sessionId: String) async -> String?

    /// Stores `text` for `sessionId`; an empty text removes the saved draft.
    func setDraft(_ text: String, for sessionId: String) async
}

/// Stores agent composer drafts in app-owned defaults so WebKit's private page stores can stay ephemeral.
///
/// A nonisolated class, not an actor: Swift 6.4 (Xcode 27) rejects an actor initializer that stores
/// a non-Sendable `UserDefaults` under this target's main-actor default isolation ("actor-isolated
/// property can not be mutated from the main actor"), with or without `nonisolated`. `UserDefaults`
/// is thread-safe and the store holds only immutable references, so `@unchecked Sendable` is sound.
// crash-allow: UserDefaults is thread-safe and both stored properties are immutable.
public nonisolated final class UserDefaultsAgentPaneDraftStore: AgentPaneDraftStoring, @unchecked Sendable {
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
    public convenience init() {
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
