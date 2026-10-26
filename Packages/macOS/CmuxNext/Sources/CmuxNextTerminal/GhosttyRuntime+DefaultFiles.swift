import Foundation
import GhosttyNextKit

extension GhosttyRuntime {
    /// Classic cmux's stable bundle identifier. Each classic channel kept its
    /// cmux-only Ghostty layer under Application Support/<bundle id>, and the
    /// others fell back to stable's; next ships under the same identifiers.
    nonisolated static let classicStableBundleIdentifier = "com.cmuxterm.app"

    /// The Ghostty config files cmux reads when `CMUX_NEXT_GHOSTTY_CONFIG`
    /// doesn't name one: Ghostty's own default files, then classic cmux's
    /// cmux-only layer, which its Settings wrote terminal settings to, so
    /// they still apply after the update (hq#1870 parity audit). It loads
    /// after the person's files, as in classic.
    nonisolated static func loadDefaultFiles(
        into config: ghostty_config_t,
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        // SAFETY: the caller passes a live config.
        unsafe ghostty_config_load_default_files(config)
        if let directory = applicationSupportDirectory,
           let path = classicConfigPath(applicationSupportDirectory: directory, bundleIdentifier: bundleIdentifier) {
            // SAFETY: the caller's live config; Swift passes a NUL-terminated copy of `path`.
            unsafe ghostty_config_load_file(config, path)
        }
    }

    /// Classic's resolution (`CmuxGhosttyConfigPathResolver`): this channel's
    /// layer, else stable's for any other channel. A layer is its non-empty
    /// `config.ghostty`, else its non-empty legacy `config` (never both),
    /// loaded by its own path so a symlink's includes resolve as in classic.
    nonisolated static func classicConfigPath(applicationSupportDirectory: URL, bundleIdentifier: String?) -> String? {
        let stable = classicStableBundleIdentifier
        let own = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? stable
        for identifier in own == stable ? [stable] : [own, stable] {
            let directory = applicationSupportDirectory.appendingPathComponent(identifier, isDirectory: true)
            for name in ["config.ghostty", "config"] {
                let url = directory.appending(path: name)
                let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 { return url.path }
            }
        }
        return nil
    }

    /// `font-size` after the default files with `applicationSupportDirectory`, for tests.
    static func defaultFilesFontSize(applicationSupportDirectory: URL, bundleIdentifier: String? = nil) -> Float? {
        _ = shared // runs ghostty_init, which config_new needs
        // SAFETY: a new config this function owns and frees once (defer), after its last use.
        guard let config = unsafe ghostty_config_new() else { return nil }
        // SAFETY: as above.
        defer { unsafe ghostty_config_free(config) }
        // SAFETY: as above.
        unsafe loadDefaultFiles(into: config, applicationSupportDirectory: applicationSupportDirectory,
                                bundleIdentifier: bundleIdentifier)
        // SAFETY: as above.
        unsafe ghostty_config_finalize(config)
        var size: Float = 0
        // SAFETY: as above; font-size is a C float.
        return unsafe configGet(config, &size, key: "font-size") ? size : nil
    }
}
