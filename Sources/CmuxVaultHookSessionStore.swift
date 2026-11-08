import Foundation

/// A cmux-owned hook-session store that a built-in Vault agent may read.
enum CmuxVaultHookSessionStore: String, Codable, Hashable, Sendable {
    case amp
}
