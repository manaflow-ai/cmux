public import Foundation

extension CloudMachineSecrets {
    /// The names `index` (``index(from:)``) holds values for, each once and sorted, whatever their
    /// scope: what the Chief card's Vault section lists (cmux issue 34263). Names only, never a value.
    public static func names(in index: [String: Int64]) -> [String] {
        Set(index.keys.compactMap { account in
            account.lastIndex(of: "/").map { String(account[account.index(after: $0)...]) }
        }).sorted()
    }

    /// This Mac's index, `~/.config/cmux/cloud-secrets.json`, which `cmux cloud secret set` writes.
    public static func indexURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/cmux/cloud-secrets.json")
    }

    /// The name cmux stores a cached provider sign-in under (`CloudCredentialLogin`): `CLAUDE_TRANSFER_<scope>`,
    /// `scope` the hex of 12 hash bytes. cmux makes it, so no person ever typed it, and nothing shows it
    /// (``signInProvider(ofName:)``).
    public static func signInName(provider: String, scope: String) -> String {
        "\(provider.uppercased())\(signInMarker)\(scope)"
    }

    /// The provider (lowercased: `claude`, `codex`) of a name ``signInName(provider:scope:)`` made; nil for
    /// any other name, such as one the person set with `cmux cloud secret set`. The Vault section shows the
    /// sign-in by its provider, never this name (cmux issue 38140).
    public static func signInProvider(ofName name: String) -> String? {
        guard let marker = name.range(of: signInMarker, options: .backwards) else { return nil }
        let provider = name[..<marker.lowerBound], scope = name[marker.upperBound...]
        guard !provider.isEmpty, provider.allSatisfy({ $0.isASCII && $0.isUppercase }),
              scope.count == 2 * signInScopeBytes, scope.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return provider.lowercased()
    }

    private static let signInMarker = "_TRANSFER_"
    /// How many hash bytes a sign-in's scope keeps.
    public static let signInScopeBytes = 12
}
