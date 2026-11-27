import CmuxNextImportSuggestions
import Foundation

/// An iTerm2 profile's colors as a Ghostty theme in the person's themes folder
/// (`~/.config/ghostty/themes`, where Ghostty and every cmux theme picker look),
/// named `iTerm2 <profile>`. Colors only, as every cmux theme file. Off the main thread.
nonisolated struct ITermThemeWriter: Sendable {
    var home: URL
    var variables: [String: String]

    var folder: URL {
        let config = variables["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: ".config", directoryHint: .isDirectory)
        return config.appending(path: "ghostty/themes", directoryHint: .isDirectory)
    }

    /// The theme name for `profile`: letters, digits, spaces, dashes and dots only.
    static func name(_ profile: String) -> String {
        let kept = profile.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_.".unicodeScalars.contains($0) }
        let clean = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return "iTerm2 \(clean.isEmpty ? "Default" : String(clean.prefix(64)))"
    }

    /// Writes the preferred profile's theme; returns its name, nil when iTerm2 has no colors to bring.
    func write() throws -> String? {
        let file = home.appending(path: "Library/Preferences/com.googlecode.iterm2.plist")
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= ImportScanner.maximumPreferencesBytes, let data = try? Data(contentsOf: file),
              let profile = ITermProfiles(data: data)?.preferred, !profile.themeLines.isEmpty else { return nil }
        let name = Self.name(profile.name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = ["# \(name): colors of the iTerm2 profile, imported by cmux"] + profile.themeLines
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: name), options: .atomic)
        return name
    }
}
