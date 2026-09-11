public import Foundation

/// Composes PATH values that cmux exports across process boundaries.
public enum CmuxPathEnvironment {
    /// Returns PATH components that can be safely represented as UTF-8.
    ///
    /// Foundation decodes malformed inherited environment bytes as the
    /// replacement scalar. Dropping that component, along with control-byte
    /// components, prevents cmux from re-exporting a value that strict tools
    /// reject while preserving empty components and their current-directory
    /// semantics.
    public static func components(from path: String?) -> [String] {
        guard let path else { return [] }
        return path
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { component in
                !component.unicodeScalars.contains(where: isMalformedScalar)
            }
    }

    /// Prepends entries once while discarding malformed inherited components.
    public static func prependingUniqueEntries(
        _ newEntries: [String],
        to currentPath: String?
    ) -> String {
        var ordered: [String] = []
        var seen: Set<String> = []
        let entries = newEntries + components(from: currentPath)
        for entry in entries where !entry.isEmpty && !entry.unicodeScalars.contains(where: isMalformedScalar) {
            if seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }
        return ordered.joined(separator: ":")
    }

    /// Prepends a standardized directory once while discarding malformed PATH components.
    public static func prependingUniqueDirectory(_ directory: String, to path: String) -> String {
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else { return path }
        let standardizedDirectory = URL(fileURLWithPath: trimmedDirectory, isDirectory: true)
            .standardizedFileURL
            .path
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return standardizedDirectory
        }

        var entries = components(from: path).filter { entry in
            let trimmedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedEntry.isEmpty else { return true }
            return URL(fileURLWithPath: trimmedEntry, isDirectory: true)
                .standardizedFileURL
                .path != standardizedDirectory
        }
        entries.insert(standardizedDirectory, at: 0)
        return entries.joined(separator: ":")
    }

    private static func isMalformedScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{FFFD}"
    }
}
