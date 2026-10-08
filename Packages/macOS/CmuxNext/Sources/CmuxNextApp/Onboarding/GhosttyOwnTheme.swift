import Foundation

/// Whether the user's Ghostty config chooses its own look (a `theme`,
/// `background` or `foreground` line), so cmux's default theme (Apple
/// System Colors, light/dark) does not apply. Reads the config files once.
nonisolated enum GhosttyOwnTheme {
    static let keys: Set<String> = ["theme", "background", "foreground"]

    static func isSet(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let paths = [".config/ghostty/config", ".config/ghostty/config.ghostty",
                     "Library/Application Support/com.mitchellh.ghostty/config",
                     "Library/Application Support/com.mitchellh.ghostty/config.ghostty"]
        return paths.contains { path in
            // concurrency-allow: a few small config files, read once when onboarding opens
            guard let text = try? String(contentsOf: home.appending(path: path), encoding: .utf8) else { return false }
            return setsLook(text)
        }
    }

    static func setsLook(_ config: String) -> Bool {
        config.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return false }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return keys.contains(key) && !value.isEmpty
        }
    }
}
