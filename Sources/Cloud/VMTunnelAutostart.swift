import CmuxFoundation
import Foundation

/// Installs the tunnel's launchd job from the app, prompting for an
/// administrator through the standard macOS dialog.
///
/// ``CmuxVPNAutostart`` owns what the job *is*; this owns getting it installed
/// without a terminal. The CLI installs the same job through sudo.
enum VMTunnelAutostart {
    enum InstallError: Error, CustomStringConvertible {
        case wireGuardMissing
        case notEnrolled
        /// Anything else. Carries no command output: the underlying tools
        /// report paths and system detail that mean nothing to the person
        /// reading a banner, so the detail is logged and this stays product
        /// copy.
        case failed

        var description: String {
            switch self {
            case .wireGuardMissing:
                return String(
                    localized: "cloud.tunnel.autostart.wireGuardMissing",
                    defaultValue: "cmux needs WireGuard on this Mac to reach your cloud machines' private network."
                )
            case .notEnrolled:
                return String(
                    localized: "cloud.tunnel.autostart.notEnrolled",
                    defaultValue: "This Mac is not on the network yet. Open a cloud machine once, then try again."
                )
            case .failed:
                return String(
                    localized: "cloud.tunnel.autostart.failed",
                    defaultValue: "cmux could not set up the private network connection. Try again."
                )
            }
        }
    }

    /// Installs the job for `interfaceName`, applying `userConfigPath`.
    ///
    /// Blocking: it waits on an authorization dialog and a privileged shell.
    /// Callers run it off the main actor.
    ///
    /// Returns false when the person cancels the dialog, which is a choice
    /// rather than a failure and leaves nothing to report.
    @discardableResult
    static func install(interfaceName: String, userConfigPath: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: userConfigPath) else {
            throw InstallError.notEnrolled
        }
        guard let wgQuick = CmuxVPNAutostart.wgQuickPath() else {
            throw InstallError.wireGuardMissing
        }
        let job = CmuxVPNAutostart(interfaceName: interfaceName)
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
            try job.scriptBody(wgQuickPath: wgQuick, userConfigPath: userConfigPath)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            try job.plistBody(userConfigPath: userConfigPath)
                .write(to: plistURL, atomically: true, encoding: .utf8)
            try job.installShell(scriptSource: scriptURL.path, plistSource: plistURL.path)
                .write(to: runnerURL, atomically: true, encoding: .utf8)
        } catch {
            cmuxDebugLog("vpn.autostart.write_failed error=\(String(reflecting: error))")
            throw InstallError.failed
        }
        return try runPrivileged(shellScriptAt: runnerURL.path)
    }

    @discardableResult
    static func uninstall(interfaceName: String) throws -> Bool {
        let job = CmuxVPNAutostart(interfaceName: interfaceName)
        let runnerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vpn-uninstall-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: runnerURL) }
        do {
            try job.uninstallShell().write(to: runnerURL, atomically: true, encoding: .utf8)
        } catch {
            cmuxDebugLog("vpn.autostart.write_failed error=\(String(reflecting: error))")
            throw InstallError.failed
        }
        return try runPrivileged(shellScriptAt: runnerURL.path)
    }

    /// Runs one shell script with administrator rights.
    ///
    /// The script is passed by path rather than interpolated into the
    /// AppleScript: the privileged sequence already contains both quote
    /// characters, and nesting it inside AppleScript's own quoting is the kind
    /// of thing that works until a path has a space in it.
    ///
    /// Cancelling reports `false` rather than throwing; AppleScript uses -128
    /// for "user cancelled".
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
            cmuxDebugLog("vpn.autostart.spawn_failed error=\(String(reflecting: error))")
            throw InstallError.failed
        }
        let errorText = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        if process.terminationStatus == 0 { return true }
        if errorText.contains("-128") { return false }
        // Diagnostics stay here; the banner gets product copy.
        cmuxDebugLog("vpn.autostart.failed status=\(process.terminationStatus) output=\(errorText)")
        throw InstallError.failed
    }
}
