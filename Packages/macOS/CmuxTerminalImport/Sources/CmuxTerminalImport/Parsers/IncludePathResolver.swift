import Foundation

/// Resolves include paths the way terminal configs write them: `~/...`, absolute, or relative to the including file.
struct IncludePathResolver {
    let homeDirectory: URL

    func resolve(_ path: String, relativeTo file: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return homeDirectory }
        if trimmed.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: false)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed, isDirectory: false)
        }
        return file.deletingLastPathComponent().appendingPathComponent(trimmed, isDirectory: false)
    }
}
