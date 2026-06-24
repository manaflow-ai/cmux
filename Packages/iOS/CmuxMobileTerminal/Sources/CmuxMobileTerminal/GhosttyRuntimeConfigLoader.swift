#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import GhosttyKit
import OSLog

private let ghosttyRuntimeConfigLoaderLog = Logger(
    subsystem: "ai.manaflow.cmux.ios",
    category: "ghostty.runtime"
)

struct GhosttyRuntimeConfigLoader {
    var fileManager: FileManager = .default
    var processInfo: ProcessInfo = .processInfo

    func loadConfig(_ config: ghostty_config_t?, theme: TerminalTheme) {
        guard let config else { return }
        #if os(iOS)
        setupiOSConfigEnvironment()
        ensureDefaultiOSConfig(theme: theme)
        ghostty_config_load_default_files(config)
        applyiOSDefaults(config, theme: theme)
        #else
        ghostty_config_load_default_files(config)
        #endif
    }

    private func setupiOSConfigEnvironment() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        setenv("XDG_CONFIG_HOME", appSupport.path, 0)
        if let env = getenv("XDG_CONFIG_HOME") {
            ghosttyRuntimeConfigLoaderLog.debug("XDG_CONFIG_HOME=\(String(cString: env), privacy: .public)")
        }
    }

    private func applyiOSDefaults(_ config: ghostty_config_t, theme: TerminalTheme) {
        // scrollback-limit: bound the mirror surface's local scrollback page
        // memory (ghostty defaults to 10MB per surface). On iOS the user-facing
        // scroll path forwards to the Mac's real surface, so local scrollback
        // exists only to feed local reads (the "View as Text" copy sheet's
        // GHOSTTY_POINT_SCREEN read). 2MB comfortably covers that sheet's
        // 5000-line budget while keeping the worst-case read (which runs on
        // the serial output queue) and per-surface memory phone-sized.
        let defaults = """
        scrollback-limit = 2000000
        font-family = Menlo
        font-size = 10
        window-padding-balance = false
        window-padding-y = 0
        cursor-style = bar
        cursor-style-blink = true
        \(theme.ghosttyColorDirectives)
        """
        let tmpFile = fileManager.temporaryDirectory.appendingPathComponent("ghostty-ios-config-\(processInfo.processIdentifier)")
        do {
            try defaults.write(to: tmpFile, atomically: true, encoding: .utf8)
            tmpFile.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            try fileManager.removeItem(at: tmpFile)
        } catch {
            ghosttyRuntimeConfigLoaderLog.error("applyiOSDefaults: failed to write config: \(error.localizedDescription, privacy: .public)")
        }

        var bgColor = ghostty_config_color_s()
        let bgKey2 = "background"
        let hasBg = ghostty_config_get(config, &bgColor, bgKey2, UInt(bgKey2.lengthOfBytes(using: .utf8)))
        ghosttyRuntimeConfigLoaderLog.debug("applyiOSDefaults: bg get=\(hasBg, privacy: .public) r=\(bgColor.r, privacy: .public) g=\(bgColor.g, privacy: .public) b=\(bgColor.b, privacy: .public)")
    }

    private func ensureDefaultiOSConfig(theme: TerminalTheme) {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let configDir = appSupport.appendingPathComponent("ghostty", isDirectory: true)
        let configFile = configDir.appendingPathComponent("config", isDirectory: false)
        guard !fileManager.fileExists(atPath: configFile.path) else { return }

        let defaultConfig = """
        font-family = Menlo
        font-size = 10
        window-padding-balance = false
        window-padding-y = 0
        cursor-style = bar
        cursor-style-blink = true
        \(theme.ghosttyColorDirectives)
        """

        do {
            try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
            try defaultConfig.write(to: configFile, atomically: true, encoding: .utf8)
        } catch {
            ghosttyRuntimeConfigLoaderLog.error("ensureDefaultiOSConfig: failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
