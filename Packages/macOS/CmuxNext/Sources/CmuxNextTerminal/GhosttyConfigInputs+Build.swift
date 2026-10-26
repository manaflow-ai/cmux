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
        // SAFETY: a new handle owned by this function until it hands it to GhosttyBuiltConfig at
        // the end; every call below that takes `config` gets this live handle.
        guard let config = unsafe ghostty_config_new() else { return nil }
        // cmux's defaults, before the user's files so theirs win.
        // SAFETY: the live config (above).
        unsafe Runtime.loadPaddingDefault(into: config)
        // SAFETY: the live config.
        unsafe Runtime.loadThemeDefault(into: config)
        // SAFETY: the live config.
        unsafe Runtime.loadKeybindDefaults(into: config)
        // SAFETY: the live config.
        unsafe GhosttyUnfocusedSplit.loadDefault(into: config)
        if let configFile {
            // SAFETY: the live config; Swift passes a NUL-terminated copy of `configFile` that
            // lives for the call.
            unsafe ghostty_config_load_file(config, configFile)
        } else {
            // SAFETY: the live config.
            unsafe Runtime.loadDefaultFiles(into: config)
        }
        // SAFETY: the live config.
        unsafe ghostty_config_load_recursive_files(config)
        let overrides = Runtime.themeLines(theme, isDark: isDark, edits: themeEdits) + Runtime.fontOverrideLines(font)
        for line in overrides {
            // SAFETY: the live config.
            unsafe Runtime.loadConfigLine(line, into: config, source: "cmux.json")
        }
        // cmux.json's window background replaces the files' opacity and
        // blur, so the surfaces, the window and the theme read one value.
        var filesOpacity: Double = 1
        // SAFETY: the live config; background-opacity is a C double.
        _ = unsafe Runtime.configGet(config, &filesOpacity, key: "background-opacity")
        var filesBlur: Int16 = 0
        // SAFETY: the live config; background-blur is an int16_t.
        _ = unsafe Runtime.configGet(config, &filesBlur, key: "background-blur")
        for line in Runtime.backgroundOverrideLines(background, configuredOpacity: filesOpacity, configuredBlur: Int(filesBlur)) {
            // SAFETY: the live config.
            unsafe Runtime.loadConfigLine(line, into: config, source: "cmux.json")
        }
        // In a translucent window the root view's material and tint are the
        // one translucent sheet; the surfaces draw cells over it with a
        // transparent default background (`GhosttyRuntimeSurfacePolicy`).
        // The resolved opacity is kept for the window and theme.
        var configured = filesOpacity
        // SAFETY: the live config; background-opacity is a C double.
        _ = unsafe Runtime.configGet(config, &configured, key: "background-opacity")
        var opacityCells = false
        // SAFETY: the live config; background-opacity-cells is a C bool.
        _ = unsafe Runtime.configGet(config, &opacityCells, key: "background-opacity-cells")
        let opacity = min(max(configured, 0), 1)
        if let line = GhosttyRuntimeSurfacePolicy.override(configuredOpacity: opacity, opacityCells: opacityCells,
                                                           ownerPaintsBackground: ownerPaintsBackground) {
            // SAFETY: the live config.
            unsafe Runtime.loadConfigLine(line, into: config, source: "cmux-next")
        }
        // SAFETY: the live config.
        unsafe ghostty_config_finalize(config)
        // SAFETY: the live config.
        unsafe Runtime.loadImageStorageDefaultIfUnset(into: config)
        var diagnostics: [String] = []
        // SAFETY: the live config.
        let count = unsafe ghostty_config_diagnostics_count(config)
        for index in 0..<count {
            // SAFETY: `index` is below the count the same live config reported; the message is a
            // NUL-terminated string the config owns, copied by String(cString:) at once.
            guard let message = unsafe ghostty_config_get_diagnostic(config, index).message else { continue }
            // SAFETY: as above.
            let text = unsafe String(cString: message)
            diagnostics.append(text)
            Runtime.logger.warning("ghostty config: \(text, privacy: .public)")
        }
        // SAFETY: ownership of the live config goes to the built config, whose one owner adopts or
        // frees it (GhosttyBuiltConfig's `config`).
        return unsafe GhosttyBuiltConfig(config: config, opacity: opacity, filesOpacity: filesOpacity, filesBlur: Int(filesBlur),
                                         diagnostics: diagnostics)
    }
}
