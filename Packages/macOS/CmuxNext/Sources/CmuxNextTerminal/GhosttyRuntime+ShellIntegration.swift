public import Foundation
import GhosttyKit

/// The shell-integration keys of the applied Ghostty config, raw as the C
/// API returns them. The App maps them onto the daemon's
/// `GhosttyShellIntegration` (this module does not import CmuxNextDaemon).
public nonisolated struct GhosttyShellIntegrationSettings: Hashable, Sendable {
    /// `shell-integration`: `none`, `detect`, `bash`, `elvish`, `fish`,
    /// `nushell` or `zsh`.
    public var mode: String
    /// `shell-integration-features` as its packed-struct bits: cursor, sudo,
    /// title, ssh-env, ssh-terminfo, path (bit 0 first).
    public var features: UInt32
    /// `cursor-style-blink`; nil when unset.
    public var cursorBlink: Bool?

    public init(mode: String, features: UInt32, cursorBlink: Bool?) {
        self.mode = mode
        self.features = features
        self.cursorBlink = cursorBlink
    }
}

extension GhosttyRuntime {
    /// Shell-integration settings of the config applied to every surface;
    /// nil when libghostty failed to load a config.
    public var shellIntegrationSettings: GhosttyShellIntegrationSettings? {
        guard let config else { return nil }
        var mode: UnsafePointer<CChar>?
        let modeName = Self.configGet(config, &mode, key: "shell-integration") ? mode.map { String(cString: $0) } : nil
        var features: UInt32 = 0
        _ = Self.configGet(config, &features, key: "shell-integration-features")
        var blink = false
        let hasBlink = Self.configGet(config, &blink, key: "cursor-style-blink")
        return GhosttyShellIntegrationSettings(mode: modeName ?? "detect", features: features, cursorBlink: hasBlink ? blink : nil)
    }

    /// The Ghostty CLI helper bundled at `<Resources>/bin/ghostty`, which
    /// Ghostty's `ssh` wrapper runs as `$GHOSTTY_BIN +ssh`. Nil when this
    /// build does not ship it.
    public nonisolated static func cliHelperPath(bundle: Bundle = .main) -> String? {
        guard let path = bundle.resourceURL?.appendingPathComponent("bin/ghostty").path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
