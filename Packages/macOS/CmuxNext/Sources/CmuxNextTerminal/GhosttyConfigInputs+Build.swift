import CmuxNextCompat
import Foundation
import GhosttyNextKit

/// The config build: the user's Ghostty config files with cmux's defaults under them and these overrides over
/// them, finalized. It reads files (the config, its `config-file` includes, the theme file at finalize), so it is
/// one ``blockingFFI(fileID:line:_:)`` scope, run where blocking is allowed: the app's files lane through
/// ``GhosttyConfigLoading``, never the main actor (Chrome posts such reads with `base::MayBlock()`,
/// base/task/thread_pool.h, and its UI thread disallows them, base/threading/thread_restrictions.h).
nonisolated extension GhosttyConfigInputs {
    /// Builds the config these inputs describe, as one checked blocking call at the caller's site. Nil when
    /// libghostty failed to initialize or to make a config.
    func buildConfig(fileID: StaticString = #fileID, line: UInt = #line) -> GhosttyBuiltConfig? {
        guard GhosttyRuntime.initializeLibrary() else { return nil }
        return blockingFFI(fileID: fileID, line: line) { makeConfig() }
    }

    private func makeConfig() -> GhosttyBuiltConfig? {
        typealias Runtime = GhosttyRuntime
        guard let config = ghostty_config_new() else { return nil }
        // cmux's defaults, before the user's files so theirs win.
        Runtime.loadPaddingDefault(into: config)
        Runtime.loadThemeDefault(into: config)
        Runtime.loadKeybindDefaults(into: config)
        GhosttyUnfocusedSplit.loadDefault(into: config)
        if let configFile {
            ghostty_config_load_file(config, configFile)
        } else {
            Runtime.loadDefaultFiles(into: config)
        }
        ghostty_config_load_recursive_files(config)
        let overrides = Runtime.themeLines(theme, isDark: isDark, edits: themeEdits) + Runtime.fontOverrideLines(font)
        for line in overrides { Self.load(line, into: config, from: "cmux.json") }
        // cmux.json's window background replaces the files' opacity and
        // blur, so the surfaces, the window and the theme read one value.
        var filesOpacity: Double = 1
        _ = Runtime.configGet(config, &filesOpacity, key: "background-opacity")
        var filesBlur: Int16 = 0
        _ = Runtime.configGet(config, &filesBlur, key: "background-blur")
        for line in Runtime.backgroundOverrideLines(background, configuredOpacity: filesOpacity, configuredBlur: Int(filesBlur)) {
            Self.load(line, into: config, from: "cmux.json")
        }
        // In a translucent window the root view's material and tint are the
        // one translucent sheet; the surfaces draw cells over it with a
        // transparent default background (`GhosttyRuntimeSurfacePolicy`).
        // The resolved opacity is kept for the window and theme.
        var configured = filesOpacity
        _ = Runtime.configGet(config, &configured, key: "background-opacity")
        var opacityCells = false
        _ = Runtime.configGet(config, &opacityCells, key: "background-opacity-cells")
        let opacity = min(max(configured, 0), 1)
        if let line = GhosttyRuntimeSurfacePolicy.override(configuredOpacity: opacity, opacityCells: opacityCells,
                                                           ownerPaintsBackground: ownerPaintsBackground) {
            Self.load(line, into: config, from: "cmux-next")
        }
        ghostty_config_finalize(config)
        Runtime.loadImageStorageDefaultIfUnset(into: config)
        var diagnostics: [String] = []
        for index in 0..<ghostty_config_diagnostics_count(config) {
            guard let message = ghostty_config_get_diagnostic(config, index).message else { continue }
            let text = String(cString: message)
            diagnostics.append(text)
            Runtime.logger.warning("ghostty config: \(text, privacy: .public)")
        }
        return GhosttyBuiltConfig(config: config, opacity: opacity, filesOpacity: filesOpacity, filesBlur: Int(filesBlur),
                                  diagnostics: diagnostics)
    }

    /// Loads one config line (`ghostty_config_load_string`) attributed to `source`.
    private static func load(_ line: String, into config: ghostty_config_t, from source: String) {
        line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), source) }
    }
}
