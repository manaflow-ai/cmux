import CmuxNextDesign
import Foundation

/// The Ghostty config files' own `font-family`: the face the terminal draws in when cmux.json sets
/// none (`terminal.fontFamily`). Pages that show code (diff, markdown, editor) follow it, as the
/// terminal does (`WebTheme.Terminal.fontFamily`). libghostty has no getter for a repeatable key,
/// so this reads the same files `GhosttyRuntime.loadConfig` loads, in its order; `config-file`
/// includes are not followed.
///
/// ```swift
/// GhosttyConfigFontFamily.read() // "JetBrains Mono", or nil when no file names one
/// ```
enum GhosttyConfigFontFamily {
    /// The first family of the last `font-family` list the files build (an empty value clears it),
    /// or nil. Reads the files on the calling thread (tests); the app reads them off the main actor
    /// (`recordLoad`).
    static func read(environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                     bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String? {
        family(inFiles: configPaths(environment: environment, home: home, applicationSupportDirectory: applicationSupportDirectory,
                                    bundleIdentifier: bundleIdentifier))
    }

    /// The files `GhosttyRuntime.loadConfig` loads, in its order: `CMUX_NEXT_GHOSTTY_CONFIG`
    /// alone, else Ghostty's default files and classic cmux's layer.
    static func configPaths(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                            bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> [String] {
        if let path = environment[GhosttyRuntime.configOverrideKey], !path.isEmpty { return [path] }
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".config")
        var files = ["config", "config.ghostty"].map { xdg.appending(path: "ghostty/\($0)").path }
        if let support = applicationSupportDirectory {
            files += ["config", "config.ghostty"].map { support.appending(path: "com.mitchellh.ghostty/\($0)").path }
            if let classic = GhosttyRuntime.classicConfigPath(applicationSupportDirectory: support, bundleIdentifier: bundleIdentifier) {
                files.append(classic)
            }
        }
        return files
    }

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

    /// A load of the user's own config (`GhosttyConfigBackground.overrideLines`): reads its family
    /// off the main actor, records it in `DesignSettings.terminalConfigFontFamily` and, when the
    /// terminal's face changed, repaints so pages resend their theme (`WebTheme.Terminal`). Only
    /// the latest load's read applies.
    static func recordLoad() {
        loads += 1
        let (load, paths) = (loads, configPaths())
        Task { // task-owner: one short file read per config load; a later load supersedes it by `loads`
            let family: String? = await Task.detached { Self.family(inFiles: paths) }.value
            guard load == loads else { return }
            let settings = DesignSettings.shared
            guard family != settings.terminalConfigFontFamily else { return }
            let before = settings.effectiveTerminalFontFamily
            settings.terminalConfigFontFamily = family
            if settings.effectiveTerminalFontFamily != before { ThemeStore.shared.repaintAll() }
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
