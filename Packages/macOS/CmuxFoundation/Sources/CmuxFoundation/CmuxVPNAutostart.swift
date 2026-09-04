import Foundation

/// The launchd job that owns this Mac's WireGuard tunnel to its Cloud VM
/// network, so nobody has to run `cmux vpn up`.
///
/// Creating a utun and installing routes needs root, and the shipping build
/// has no NetworkExtension entitlement, so something privileged has to own the
/// tunnel. A LaunchDaemon is that something: authorize once, and launchd
/// brings the tunnel up at every boot from then on.
///
/// This type is the single definition of that job — its identity, its file
/// layout, and the shell it runs. It lives in CmuxFoundation because the app
/// installs it from the Machines panel and the CLI installs it from `cmux vpn
/// install`, and two privileged flows that drift in paths or permissions are
/// how one of them ends up installing something the other cannot remove.
///
/// Everything here is a pure value: the callers own how the shell is run
/// (the app through an authorization prompt, the CLI through sudo).
public struct CmuxVPNAutostart: Sendable, Equatable {
    /// The tunnel this job owns, named the way `VMTunnelManager` names its
    /// interface (`cmux`, `cmux-staging`, `cmux-local`, …).
    ///
    /// Every path and the launchd label carry it. A single fixed identity
    /// meant installing the staging tunnel silently replaced the production
    /// job, leaving only whichever was installed last coming up at boot.
    public let interfaceName: String

    public init(interfaceName: String) {
        self.interfaceName = interfaceName
    }

    public var label: String { "com.cmuxterm.vpn.autostart.\(interfaceName)" }
    public var plistPath: String { "/Library/LaunchDaemons/\(label).plist" }
    public var scriptPath: String { "\(Self.privilegedDirectory)/cmux-vpn-autostart-\(interfaceName)" }

    /// Root-owned home for both the helper and the config it applies.
    public static let privilegedDirectory = "/usr/local/libexec/cmux-vpn"

    /// The config the daemon actually applies, owned by root.
    ///
    /// wg-quick takes the interface name from the filename, so this keeps the
    /// same basename as the user's copy.
    public var privilegedConfigPath: String {
        "\(Self.privilegedDirectory)/\(interfaceName).conf"
    }

    /// Config directives that make wg-quick run arbitrary commands as root.
    /// Stripped on the way into the root-owned copy.
    public static let executableDirectives = ["preup", "postup", "predown", "postdown"]

    /// Whether the job is installed. This is about the job, not the tunnel.
    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// wg-quick, wherever the package manager put it.
    public static let wgQuickCandidates = [
        "/opt/homebrew/bin/wg-quick",
        "/usr/local/bin/wg-quick",
        "/opt/local/bin/wg-quick",
    ]

    public static func wgQuickPath() -> String? {
        wgQuickCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The privileged helper launchd runs.
    ///
    /// It does not apply the user's config directly. That file is writable by
    /// the signed-in user, and wg-quick runs a config's `PostUp`/`PreUp`/
    /// `PostDown`/`PreDown` as root — so applying it as root would let any
    /// process running as the user execute code as root just by writing a line
    /// to it, every time the tunnel came up. Instead the helper copies the
    /// config into a root-owned file with those directives stripped, and
    /// applies that. The user can still change their own keys and addresses,
    /// which are theirs; they cannot hand root a command.
    ///
    /// launchd starts jobs with a minimal environment, so wg-quick's own
    /// directory goes on PATH explicitly — it shells out to `wg`, which
    /// Homebrew does not put anywhere launchd looks.
    public func scriptBody(wgQuickPath: String, userConfigPath: String) -> String {
        let wgDirectory = (wgQuickPath as NSString).deletingLastPathComponent
        let stripPattern = Self.executableDirectives.joined(separator: "|")
        return """
        #!/bin/sh
        # Installed by cmux. Brings up this Mac's tunnel to its Cloud VM network.
        set -e
        PATH="\(wgDirectory):/usr/bin:/bin:/usr/sbin:/sbin"
        export PATH
        SRC="\(userConfigPath)"
        DEST="\(privilegedConfigPath)"
        [ -f "$SRC" ] || exit 0
        umask 077
        TMP="$(mktemp)"
        trap 'rm -f "$TMP"' EXIT
        # The source is user-writable; these directives would run as root.
        grep -v -i -E '^[[:space:]]*(\(stripPattern))[[:space:]]*=' "$SRC" > "$TMP"
        /usr/bin/install -o root -g wheel -m 600 "$TMP" "$DEST"
        # Re-apply rather than skip: the config may name a peer the live
        # interface does not have, which reads as up while reaching nothing.
        wg-quick down "$DEST" 2>/dev/null || true
        exec wg-quick up "$DEST"
        """
    }

    public func plistBody(userConfigPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(scriptPath)</string></array>
          <key>RunAtLoad</key><true/>
          <key>WatchPaths</key>
          <array><string>\(userConfigPath)</string></array>
          <key>StandardErrorPath</key><string>/var/log/\(label).log</string>
        </dict>
        </plist>
        """
    }

    /// The one privileged shell an install runs. Kept as a single script so a
    /// single authorization covers every step, and `bootstrap` right after
    /// `bootout` means installing also brings the tunnel up now rather than at
    /// the next boot.
    public func installShell(scriptSource: String, plistSource: String) -> String {
        """
        set -e
        /usr/bin/install -d -o root -g wheel -m 755 '\(Self.privilegedDirectory)'
        /usr/bin/install -o root -g wheel -m 755 '\(scriptSource)' '\(scriptPath)'
        /usr/bin/install -o root -g wheel -m 644 '\(plistSource)' '\(plistPath)'
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootstrap system '\(plistPath)'
        """
    }

    public func uninstallShell() -> String {
        """
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/rm -f '\(plistPath)' '\(scriptPath)' '\(privilegedConfigPath)'
        """
    }
}
