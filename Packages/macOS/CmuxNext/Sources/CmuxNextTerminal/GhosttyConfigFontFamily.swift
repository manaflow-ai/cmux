import CmuxNextDesign
import Foundation

/// The Ghostty config's own `font-family`: the face the terminal draws in when cmux.json sets
/// none (`terminal.fontFamily`). Pages that show code (diff, markdown, editor) follow it, as the
/// terminal does (`WebTheme.Terminal.fontFamily`). libghostty has no getter for a repeatable key,
/// so this reads the files the loaded config came from (`loadedConfigFiles`: the config files and
/// their `config-file` includes, in load order) and applies their `font-family` lines in order.
///
/// ```swift
/// GhosttyConfigFontFamily.family(inFiles: GhosttyRuntime.loadedFiles(configFile: path)) // "Fira Code"
/// ```
enum GhosttyConfigFontFamily {
    /// The family `paths` name, read in order.
    nonisolated static func family(inFiles paths: [String]) -> String? {
        var families: [String] = []
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            families = fontFamilies(configText: text, after: families)
        }
        return families.first
    }

    private static var loads = 0

    /// A load of the user's own config, applied on the main actor (`recordUserConfigLoad`; only the shared
    /// runtime loads it): reads its family off the main actor, records it in
    /// `DesignSettings.terminalConfigFontFamily`, which repaints pages when the terminal's face
    /// changed (`WebTheme.Terminal`). Only the latest load's read applies.
    static func recordLoad() {
        loads += 1
        let load = loads
        Task { // task-owner: one short file read per config load; a later load supersedes it by `loads`
            // After the load finished: the runtime's config is the one just loaded.
            let paths = GhosttyRuntime.shared.loadedConfigFiles
            let family: String? = await Task.detached { Self.family(inFiles: paths) }.value
            guard load == loads else { return }
            let settings = DesignSettings.shared
            if family != settings.terminalConfigFontFamily { settings.terminalConfigFontFamily = family }
        }
    }

    /// `families` after the `font-family` lines of one config file's `text`.
    nonisolated static func fontFamilies(configText text: String, after families: [String] = []) -> [String] {
        var result = families
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "font-family" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if value.isEmpty { result = [] } else { result.append(value) }
        }
        return result
    }
}
