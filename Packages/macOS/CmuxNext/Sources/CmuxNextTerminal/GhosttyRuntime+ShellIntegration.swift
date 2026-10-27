public import CmuxNextCompat
public import Foundation
import GhosttyNextKit

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
        // SAFETY: `config` is the live applied config (GhosttyRuntime's note), held for this call.
        return unsafe Self.shellIntegrationSettings(config)
    }

    /// Shell-integration settings of the file at `path` loaded alone, with
    /// its `config-file` includes, as libghostty loads a config file: the
    /// oracle for the daemon's own reader (schemas/ghostty-shell-features).
    /// Nil when libghostty cannot make a config.
    public static func shellIntegrationSettings(configFile path: String) -> GhosttyShellIntegrationSettings? {
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        unsafe withScratchConfig(load: { config in
            // SAFETY: as above; Swift passes a NUL-terminated copy of `path` for the call.
            unsafe ghostty_config_load_file(config, path)
            // SAFETY: as above.
            unsafe ghostty_config_load_recursive_files(config)
        }, read: {
            // SAFETY: as above.
            unsafe shellIntegrationSettings($0)
        })
    }

    /// `config` is a live handle the caller holds for the call.
    private static func shellIntegrationSettings(_ config: ghostty_config_t) -> GhosttyShellIntegrationSettings {
        // SAFETY: the caller's live config; shell-integration is a string (the enum's name).
        let modeName = unsafe configString(config, key: "shell-integration")
        var features: UInt32 = 0
        // SAFETY: the caller's live config; shell-integration-features is a uint32 bit set.
        _ = unsafe configGet(config, &features, key: "shell-integration-features")
        var blink = false
        // SAFETY: the caller's live config; cursor-style-blink is a C bool.
        let hasBlink = unsafe configGet(config, &blink, key: "cursor-style-blink")
        return GhosttyShellIntegrationSettings(mode: modeName ?? "detect", features: features, cursorBlink: hasBlink ? blink : nil)
    }

    /// `cursor-style` and `cursor-style-blink` of the applied config: the
    /// cursor a fresh surface starts with. nil when no config loaded.
    public var cursorDefaults: (style: String, blink: Bool?)? {
        guard let config else { return nil }
        // SAFETY: the runtime's live applied config (GhosttyRuntime.config); cursor-style is a
        // string (the enum's name).
        let name = unsafe Self.configString(config, key: "cursor-style")
        var blink = false
        // SAFETY: as above; cursor-style-blink is a C bool.
        let hasBlink = unsafe Self.configGet(config, &blink, key: "cursor-style-blink")
        return (name ?? "block", hasBlink ? blink : nil)
    }

    /// `desktop-notifications`: whether terminal programs may post desktop
    /// notifications (OSC 9/777/99). True when no config loaded, as in Ghostty.
    public var desktopNotificationsEnabled: Bool {
        guard let config else { return true }
        var enabled = true
        // SAFETY: the runtime's live applied config (GhosttyRuntime.config); a C bool.
        return unsafe Self.configGet(config, &enabled, key: "desktop-notifications") ? enabled : true
    }

    /// The Ghostty CLI helper bundled at `<Resources>/bin/ghostty`, which
    /// Ghostty's `ssh` wrapper runs as `$GHOSTTY_BIN +ssh`. Nil when this
    /// build does not ship it. `isExecutable` is the disk check (a test's own).
    public nonisolated static func cliHelperPath(bundle: Bundle = .main,
                                                 isExecutable: (String) -> Bool = { FileManager.checked.isExecutableFile(atPath: $0) }) -> String? {
        guard let path = bundle.resourceURL?.appendingPathComponent("bin/ghostty").path, isExecutable(path) else { return nil }
        return path
    }
}
