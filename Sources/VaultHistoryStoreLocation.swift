import Foundation

/// Resolves the bundle-scoped Application Support file used by History persistence.
struct VaultHistoryStoreLocation: Sendable {
    private static let fallbackBundleIdentifier = "com.cmuxterm.app"

    let applicationSupportDirectory: URL
    let bundleIdentifier: String?

    var fileURL: URL {
        let trimmedIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = trimmedIdentifier.flatMap { identifier in
            identifier.isEmpty ? nil : identifier
        } ?? Self.fallbackBundleIdentifier
        let allowedScalars = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
        let safeIdentifier = identifier.unicodeScalars
            .map { allowedScalars.contains($0) ? String($0) : "_" }
            .joined()
        return applicationSupportDirectory
            .appending(path: "cmux", directoryHint: .isDirectory)
            .appending(
                path: "vault-history-\(safeIdentifier).jsonl",
                directoryHint: .notDirectory
            )
    }
}
