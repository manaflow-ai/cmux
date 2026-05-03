import Foundation

// MARK: - Account

struct ProviderAccount: Identifiable, Equatable, Codable {
    let id: UUID
    let providerId: String     // "claude" | "codex" | ...
    var displayName: String
    /// The keychain service name captured at account creation. Persisted so
    /// removal and secret lookups still target the correct keychain slot even
    /// if the provider definition is later renamed or stops shipping in the
    /// registry. `nil` for accounts written by earlier builds — those fall
    /// back to the current `keychainServiceResolver` lookup.
    var keychainService: String?
}

// MARK: - Secret

struct ProviderSecret: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let fields: [String: String]   // dynamic credential payload

    /// The secret intentionally elides every field value so that
    /// accidentally printing / logging / Sentry-breadcrumbing a
    /// `ProviderSecret` (including via string interpolation, dictionary
    /// dumps, or Xcode quick-look) never leaks a live session token.
    /// The defense is cheap and catches a whole class of future mistakes.
    var description: String {
        let keys = fields.keys.sorted().joined(separator: ", ")
        return "ProviderSecret(fields: [\(keys)] = <redacted>)"
    }

    var debugDescription: String { description }

    /// Reflection APIs (`dump`, Xcode quick-look, swift-playgrounds) walk the
    /// stored property tree independently of `description`. Overriding the
    /// mirror keeps raw credential strings from appearing in debugger dumps
    /// even when a caller bypasses `CustomStringConvertible`.
    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "fields": fields.keys.sorted().map { "\($0): <redacted>" }
            ],
            displayStyle: .struct
        )
    }
}

// MARK: - Store Errors

enum ProviderAccountStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case decoding
    case notFound

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return String(localized: "providers.accounts.error.keychainStatus", defaultValue: "Keychain error (OSStatus \(status)). Check macOS Keychain Access permissions.")
        case .decoding:
            return String(localized: "providers.accounts.error.decoding", defaultValue: "Failed to decode account credentials from Keychain.")
        case .notFound:
            return String(localized: "providers.accounts.error.notFound", defaultValue: "Account not found.")
        }
    }
}
