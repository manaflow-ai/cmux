import Foundation
import GhosttyNextKit

extension GhosttyRuntime {
    /// Classic cmux's channels, the stable app first. Each kept its
    /// cmux-only Ghostty layer under Application Support/<bundle id>; next
    /// ships under the same bundle identifiers.
    static let classicBundleIdentifiers = ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc",
                                           "com.cmuxterm.app.staging"]

    /// The Ghostty config files cmux reads when `CMUX_NEXT_GHOSTTY_CONFIG`
    /// doesn't name one: Ghostty's own default files, then classic cmux's
    /// cmux-only layer, which its Settings wrote terminal settings to, so
    /// they still apply after the update (hq#1870 parity audit). It loads
    /// after the person's files, as in classic.
    static func loadDefaultFiles(
        into config: ghostty_config_t,
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        ghostty_config_load_default_files(config)
        if let directory = applicationSupportDirectory,
           let path = classicConfigPath(applicationSupportDirectory: directory, bundleIdentifier: bundleIdentifier) {
            ghostty_config_load_file(config, path)
        }
    }

    /// The layer of this channel, else of the first classic channel that has
    /// one: its non-empty `config.ghostty`, else its non-empty legacy
    /// `config` (classic never layered the two).
    static func classicConfigPath(applicationSupportDirectory: URL, bundleIdentifier: String?) -> String? {
        let own = bundleIdentifier.map { classicBundleIdentifiers.contains($0) ? [$0] : [] } ?? []
        for identifier in own + classicBundleIdentifiers {
            let directory = applicationSupportDirectory.appendingPathComponent(identifier, isDirectory: true)
            for name in ["config.ghostty", "config"] {
                let url = directory.appending(path: name).resolvingSymlinksInPath()
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 { return url.path }
            }
        }
        return nil
    }

    /// `font-size` after the default files with `applicationSupportDirectory`, for tests.
    static func defaultFilesFontSize(applicationSupportDirectory: URL, bundleIdentifier: String? = nil) -> Float? {
        _ = shared // runs ghostty_init, which config_new needs
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        loadDefaultFiles(into: config, applicationSupportDirectory: applicationSupportDirectory,
                         bundleIdentifier: bundleIdentifier)
        ghostty_config_finalize(config)
        var size: Float = 0
        return configGet(config, &size, key: "font-size") ? size : nil
    }
}
