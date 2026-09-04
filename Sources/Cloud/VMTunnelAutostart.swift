import Foundation

/// The launchd job that owns this Mac's WireGuard tunnel, so nobody has to run
/// `cmux vpn up`.
///
/// Creating a utun and installing routes needs root. The shipping build has no
/// NetworkExtension entitlement, so the app cannot hold the tunnel itself and
/// something privileged has to. That something is a LaunchDaemon: the person
/// authorizes once, and launchd brings the tunnel up at every boot from then
/// on — no terminal, and no second prompt.
///
/// The job also watches the config file. The app rewrites it whenever the
/// enrollment changes (new keys, a different account), and a tunnel still
/// carrying the previous peer reads as up while reaching nothing, so a write
/// re-applies the tunnel instead of leaving it wrong until the next reboot.
///
/// Install runs through `osascript`'s admin prompt rather than `sudo`, because
/// the app has no terminal to read a password from; the CLI's `cmux vpn
/// install` builds the same script and plist through `sudo` instead.
enum VMTunnelAutostart {
    static let label = "com.cmuxterm.vpn.autostart"
    static var plistPath: String { "/Library/LaunchDaemons/\(label).plist" }
    static var scriptPath: String { "/usr/local/libexec/cmux-vpn-autostart" }

    /// wg-quick, wherever the package manager put it.
    static let wgQuickCandidates = [
        "/opt/homebrew/bin/wg-quick",
        "/usr/local/bin/wg-quick",
        "/opt/local/bin/wg-quick",
    ]

    static func wgQuickPath() -> String? {
        wgQuickCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether the job is installed. This is about the job, not the tunnel:
    /// `VMTunnelManager.wgQuickInterfaceUp()` answers whether it is up now.
    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// The privileged helper. launchd starts jobs with a minimal environment,
    /// so wg-quick's own directory goes on PATH explicitly — it shells out to
    /// `wg`, which Homebrew does not put anywhere launchd looks.
    static func scriptBody(wgQuickPath: String, configPath: String) -> String {
        let wgDirectory = (wgQuickPath as NSString).deletingLastPathComponent
        return """
        #!/bin/sh
        # Installed by cmux. Brings up this Mac's tunnel to its Cloud VM network.
        set -e
        PATH="\(wgDirectory):/usr/bin:/bin:/usr/sbin:/sbin"
        export PATH
        CONFIG="\(configPath)"
        [ -f "$CONFIG" ] || exit 0
        # Re-apply rather than skip: the config may name a peer the live
        # interface does not have, which reads as up while reaching nothing.
        wg-quick down "$CONFIG" 2>/dev/null || true
        exec wg-quick up "$CONFIG"
        """
    }

    static func plistBody(configPath: String) -> String {
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
          <array><string>\(configPath)</string></array>
          <key>StandardErrorPath</key><string>/var/log/cmux-vpn-autostart.log</string>
        </dict>
        </plist>
        """
    }

    /// The one privileged shell the install runs. Kept as a single script so a
    /// single authorization covers every step, and `bootstrap` immediately
    /// after `bootout` means installing also brings the tunnel up now rather
    /// than at the next boot.
    static func installShell(scriptSource: String, plistSource: String) -> String {
        """
        set -e
        /usr/bin/install -d -o root -g wheel -m 755 '\((scriptPath as NSString).deletingLastPathComponent)'
        /usr/bin/install -o root -g wheel -m 755 '\(scriptSource)' '\(scriptPath)'
        /usr/bin/install -o root -g wheel -m 644 '\(plistSource)' '\(plistPath)'
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootstrap system '\(plistPath)'
        """
    }

    static func uninstallShell() -> String {
        """
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/rm -f '\(plistPath)' '\(scriptPath)'
        """
    }
}

// MARK: - Installing from the app

extension VMTunnelAutostart {
    enum InstallError: Error, CustomStringConvertible {
        case wgQuickMissing
        case failed(String)

        var description: String {
            switch self {
            case .wgQuickMissing:
                return String(
                    localized: "cloud.tunnel.autostart.wgMissing",
                    defaultValue: "WireGuard is not installed on this Mac. Install it with: brew install wireguard-tools"
                )
            case .failed(let detail):
                return detail
            }
        }
    }

    /// Installs the job, prompting for an administrator once through the
    /// standard macOS dialog.
    ///
    /// The whole privileged sequence goes into a temp script and AppleScript
    /// runs that one path, rather than interpolating it into a `do shell
    /// script` string: the sequence already contains both quote characters,
    /// and nesting it inside AppleScript's own quoting is the kind of thing
    /// that works until a path has a space in it.
    ///
    /// Running this while the job is already installed is fine and is how a
    /// re-enrollment is repaired: the script re-applies the tunnel.
    static func installWithAdminPrompt(configPath: String) throws {
        guard let wgQuick = wgQuickPath() else { throw InstallError.wgQuickMissing }

        let directory = FileManager.default.temporaryDirectory
        let scriptURL = directory.appendingPathComponent("cmux-vpn-autostart-\(UUID().uuidString)")
        let plistURL = directory.appendingPathComponent("cmux-vpn-autostart-\(UUID().uuidString).plist")
        let runnerURL = directory.appendingPathComponent("cmux-vpn-install-\(UUID().uuidString).sh")
        defer {
            for url in [scriptURL, plistURL, runnerURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        do {
            try scriptBody(wgQuickPath: wgQuick, configPath: configPath)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            try plistBody(configPath: configPath)
                .write(to: plistURL, atomically: true, encoding: .utf8)
            try installShell(scriptSource: scriptURL.path, plistSource: plistURL.path)
                .write(to: runnerURL, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.failed(error.localizedDescription)
        }

        try runPrivileged(shellScriptAt: runnerURL.path)
    }

    static func uninstallWithAdminPrompt() throws {
        let runnerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vpn-uninstall-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: runnerURL) }
        do {
            try uninstallShell().write(to: runnerURL, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.failed(error.localizedDescription)
        }
        try runPrivileged(shellScriptAt: runnerURL.path)
    }

    /// Cancelling the authorization dialog is a choice, not a failure, so it
    /// reports as `false` rather than throwing an error the UI would show as a
    /// problem. AppleScript uses -128 for "user cancelled".
    @discardableResult
    private static func runPrivileged(shellScriptAt path: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/bin/sh \" & quoted form of \"\(path)\" with administrator privileges",
        ]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw InstallError.failed(error.localizedDescription)
        }
        let errorText = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        if process.terminationStatus == 0 { return true }
        if errorText.contains("-128") { return false }
        throw InstallError.failed(
            errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Setting up the tunnel failed (exit \(process.terminationStatus))."
                : errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
