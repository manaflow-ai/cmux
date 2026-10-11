import Foundation
import GhosttyNextKit

extension GhosttyRuntime {
    /// The Ghostty config files cmux reads when `CMUX_NEXT_GHOSTTY_CONFIG`
    /// doesn't name one: Ghostty's own default files.
    static func loadDefaultFiles(
        into config: ghostty_config_t,
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) {
        ghostty_config_load_default_files(config)
    }

    /// `font-size` after the default files with `applicationSupportDirectory`, for tests.
    static func defaultFilesFontSize(applicationSupportDirectory: URL) -> Float? {
        _ = shared // runs ghostty_init, which config_new needs
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        loadDefaultFiles(into: config, applicationSupportDirectory: applicationSupportDirectory)
        ghostty_config_finalize(config)
        var size: Float = 0
        return configGet(config, &size, key: "font-size") ? size : nil
    }
}
