import Foundation

// MARK: - Provider Registry

enum ProviderRegistry {
    /// All registered providers (including stubs with empty credentialFields).
    /// Each concrete provider appends itself in its own source commit so this
    /// file stays buildable in isolation.
    static var all: [UsageProvider] { [Providers.claude, Providers.codex] }

    /// Providers ready for use in the UI — excludes stubs with empty credentialFields.
    static var ui: [UsageProvider] { all.filter { !$0.credentialFields.isEmpty } }

    static func provider(id: String) -> UsageProvider? {
        all.first { $0.id == id }
    }
}

// MARK: - Providers namespace

enum Providers {}
