/// An owner of some tabs' content that takes the content lifecycle's effects for them and manages their memory
/// (p07-memory.md 3.C): page tabs' views, conversation tabs' transcripts. `Token` is the lifecycle's effect token.
/// Each call answers false for a key the owner does not hold, which then takes the content cache's own path
/// (terminals, browser hibernation).
@MainActor
package protocol ContentLifecycleOwner<Token>: AnyObject {
    associatedtype Token
    /// `key`'s content exists and is live; the owner, not the terminal warm set, manages its memory.
    func contentAdopted(_ key: String) -> Bool
    /// `key` shows (its `reveal`).
    func contentDidShow(_ key: String) -> Bool
    /// `key` stopped showing (its `conceal`, under `token`).
    func contentDidHide(_ key: String, token: Token) -> Bool
    /// `key`'s content goes (its `release` effect after a `hibernate`).
    func releaseContent(_ key: String, token: Token) -> Bool
    /// `key`'s content is made again and answers its `restore` effect.
    func restoreContent(_ key: String, token: Token) -> Bool
}

/// The content cache's ``ContentLifecycleOwner``s, in the order they were added (each feature that discards a
/// kind of content adds its owner once, at launch). Every effect goes to the first owner that holds its key.
@MainActor
package final class ContentLifecycleOwners<Token> {
    private var owners: [any ContentLifecycleOwner<Token>] = []

    package init() {}

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    /// No owner was added (every discard feature is off).
    package var isEmpty: Bool { owners.isEmpty }

    /// Adds `owner`, kept for the cache's life.
    package func add(_ owner: any ContentLifecycleOwner<Token>) { owners.append(owner) }

    /// The first added owner of type `T` (tests, diagnostics).
    package func first<T>(_: T.Type) -> T? { owners.lazy.compactMap { $0 as? T }.first }

    package func contentAdopted(_ key: String) -> Bool { owners.contains { $0.contentAdopted(key) } }

    package func contentDidShow(_ key: String) -> Bool { owners.contains { $0.contentDidShow(key) } }

    package func contentDidHide(_ key: String, token: Token) -> Bool { owners.contains { $0.contentDidHide(key, token: token) } }

    package func releaseContent(_ key: String, token: Token) -> Bool { owners.contains { $0.releaseContent(key, token: token) } }

    package func restoreContent(_ key: String, token: Token) -> Bool { owners.contains { $0.restoreContent(key, token: token) } }
}
