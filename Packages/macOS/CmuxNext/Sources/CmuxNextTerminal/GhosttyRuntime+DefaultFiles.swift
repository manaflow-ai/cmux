import CmuxNextCompat
import Foundation
import GhosttyNextKit

extension GhosttyRuntime {
    /// The consented import publishes this file beside NEXT's settings. It is also a
    /// reload candidate so terminals already open pick it up when the import finishes.
    nonisolated static var importedClassicConfig: URL {
        let override = ProcessInfo.processInfo.environment[BuildStatePaths.settingsFileKey]
        let settings = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? BuildStatePaths.current.settingsFile
        return settings.deletingLastPathComponent().appending(path: "classic-ghostty/config.ghostty")
    }

    static func loadDefaultFiles(into config: ghostty_config_t, importedLayer: URL = importedClassicConfig) {
        ghostty_config_load_default_files(config)
        // Ghostty resolves optional includes with the other config files. A fresh
        // install has no imported layer. Keep the path on a single config line.
        let path = importedLayer.path
        guard path.rangeOfCharacter(from: .newlines) == nil else { return }
        let include = "config-file = ?\(path)"
        include.withCString { ghostty_config_load_string(config, $0, UInt(include.utf8.count), "cmux-next") }
    }

    static func defaultFilesFontSize(importedLayer: URL) -> Float? {
        _ = shared // runs ghostty_init, which config_new needs
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        loadDefaultFiles(into: config, importedLayer: importedLayer)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        var size: Float = 0
        return configGet(config, &size, key: "font-size") ? size : nil
    }
}
