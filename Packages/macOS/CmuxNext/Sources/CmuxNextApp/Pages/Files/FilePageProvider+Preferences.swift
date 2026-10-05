import Foundation

/// The keys a file page may write through `cmux.<page>.setPreference` (PAGE-PREFS).
extension FilePageProvider {
    /// Keys only the host (or the user in Settings) writes, never a page.
    nonisolated static let hostOnlyKeys: Set<String> = ["markdown.remoteImages", "files.roots"]

    nonisolated static func isPreferenceKey(_ key: String, section: String) -> Bool {
        guard !hostOnlyKeys.contains(key), !hostOnlyKeys.contains(where: { key.hasPrefix($0 + ".") }) else { return false }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 6, parts[0] == section, key.count <= 96 else { return false }
        return parts.dropFirst().allSatisfy { part in
            guard let first = part.first, first.isLetter, first.isASCII else { return false }
            return part.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII }
        }
    }
}
