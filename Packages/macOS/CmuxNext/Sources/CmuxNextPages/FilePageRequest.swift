public import CmuxNextSettings
public import Foundation

/// Request validation shared by the Markdown viewer and code editor.
public nonisolated enum FilePageRequest {
    public static func path(_ value: JSONValue?) throws -> URL {
        guard let path = value?.stringValue, path.hasPrefix("/"), !path.contains("\u{0}") else {
            throw PageError.invalidParams("path must be absolute")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Keys only the host (or the user in Settings) writes, never a page.
    private static let hostOnlyKeys: Set<String> = ["markdown.remoteImages", "files.roots"]

    public static func isPreferenceKey(_ key: String, section: String) -> Bool {
        guard !hostOnlyKeys.contains(key), !hostOnlyKeys.contains(where: { key.hasPrefix($0 + ".") }) else { return false }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 6, parts[0] == section, key.count <= 96 else { return false }
        return parts.dropFirst().allSatisfy { part in
            guard let first = part.first, first.isLetter, first.isASCII else { return false }
            return part.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII }
        }
    }
}
