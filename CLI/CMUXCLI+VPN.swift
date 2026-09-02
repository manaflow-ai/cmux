import Darwin
import Foundation

/// `cmux vpn` — the WireGuard tunnel between this Mac and the user's private
/// Cloud VM network.
///
/// Cloud machines live on one private network per account and open no public
/// inbound port, so their session daemons are reachable only through this
/// tunnel. The cmux app owns enrollment (keypair, device identity, the config
/// file at `~/.cmuxterm/wireguard/cmux.conf`); this command owns the
/// privileged bring-up, because creating a utun and installing routes needs
/// root and `sudo` in the user's own terminal is the honest way to ask.
///
/// Two backends, one command:
/// - **wg-quick** (shipping): `up` runs `sudo wg-quick up` on the app-written
///   config. Requires `brew install wireguard-tools`.
/// - **NetworkExtension** (long-term, entitlement-gated): when a build carries
///   the packet-tunnel entitlement, the app manages the tunnel itself and
///   `cmux vpn up` will hand off to it instead of shelling out. The socket
///   response advertises `network_extension_available` so this command steers
///   without a new CLI release.
extension CMUXCLI {
    private static let wgQuickCandidates = [
        "/opt/homebrew/bin/wg-quick",
        "/usr/local/bin/wg-quick",
        "/opt/local/bin/wg-quick",
    ]

    func runVPNCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let sub = commandArgs.first?.lowercased() ?? "status"
        switch sub {
        case "up":
            try runVPNUp(client: client, jsonOutput: jsonOutput)
        case "down":
            try runVPNDown(client: client, jsonOutput: jsonOutput)
        case "status":
            try runVPNStatus(client: client, jsonOutput: jsonOutput)
        case "revoke":
            try runVPNRevoke(client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "Usage: cmux vpn <up|down|status|revoke>")
        }
    }

    private func runVPNUp(client: SocketClient, jsonOutput: Bool) throws {
        // The app enrolls (idempotently) and writes the completed config; this
        // process never sees the private key except as bytes inside that
        // 0600 file it does not read.
        let response = try client.sendV2(method: "vm.tunnel_config", responseTimeout: 120)
        guard let configPath = response["config_path"] as? String, !configPath.isEmpty else {
            throw CLIError(message: "The cmux app did not return a tunnel config. Update cmux and retry.")
        }
        let interfaceUp = (response["interface_up"] as? Bool) ?? false

        if interfaceUp {
            if jsonOutput {
                print(jsonString(["status": "up", "config_path": configPath, "changed": false]))
            } else {
                print(String(localized: "cli.vpn.alreadyUp", defaultValue: "Tunnel is already up."))
                printVPNAddresses(response)
            }
            return
        }

        guard let wgQuick = Self.firstExecutable(Self.wgQuickCandidates) else {
            throw CLIError(message: """
                wg-quick is not installed, and this cmux build cannot manage the tunnel itself.

                What to do:
                  brew install wireguard-tools
                  cmux vpn up
                """)
        }

        if !jsonOutput {
            if (response["created"] as? Bool) == true {
                print(String(localized: "cli.vpn.enrolled", defaultValue: "Enrolled this Mac on your Cloud VM network."))
            } else if (response["rotated"] as? Bool) == true {
                print(String(localized: "cli.vpn.rotated", defaultValue: "Refreshed this Mac's tunnel keys."))
            }
            print(String(localized: "cli.vpn.bringingUp", defaultValue: "Bringing the tunnel up (sudo will prompt for your password)…"))
        }
        let status = runInteractiveProcess(
            executablePath: "/usr/bin/sudo",
            arguments: [wgQuick, "up", configPath]
        )
        guard status == 0 else {
            throw CLIError(message: """
                wg-quick up failed (exit \(status)).

                What to do:
                  Check the output above. If the interface half-started, run `cmux vpn down` first, then retry.
                """)
        }
        if jsonOutput {
            print(jsonString(["status": "up", "config_path": configPath, "changed": true]))
        } else {
            print(String(localized: "cli.vpn.up", defaultValue: "Tunnel is up."))
            printVPNAddresses(response)
        }
    }

    private func runVPNDown(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        let configPath = (response["config_path"] as? String) ?? ""
        let interfaceUp = (response["interface_up"] as? Bool) ?? false
        if !interfaceUp {
            if jsonOutput {
                print(jsonString(["status": "down", "changed": false]))
            } else {
                print(String(localized: "cli.vpn.notUp", defaultValue: "Tunnel is not up."))
            }
            return
        }
        guard !configPath.isEmpty, FileManager.default.fileExists(atPath: configPath) else {
            throw CLIError(message: "No tunnel config found at \(configPath). Run `cmux vpn up` to re-create it.")
        }
        guard let wgQuick = Self.firstExecutable(Self.wgQuickCandidates) else {
            throw CLIError(message: "wg-quick is not installed. Install with: brew install wireguard-tools")
        }
        let status = runInteractiveProcess(
            executablePath: "/usr/bin/sudo",
            arguments: [wgQuick, "down", configPath]
        )
        guard status == 0 else {
            throw CLIError(message: "wg-quick down failed (exit \(status)). Check the output above.")
        }
        if jsonOutput {
            print(jsonString(["status": "down", "changed": true]))
        } else {
            print(String(localized: "cli.vpn.down", defaultValue: "Tunnel is down."))
        }
    }

    private func runVPNStatus(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let interfaceUp = (response["interface_up"] as? Bool) ?? false
        let configPresent = (response["config_present"] as? Bool) ?? false
        let neAvailable = (response["network_extension_available"] as? Bool) ?? false
        if interfaceUp {
            print(String(localized: "cli.vpn.status.up", defaultValue: "Tunnel: up"))
        } else if configPresent {
            print(String(localized: "cli.vpn.status.down", defaultValue: "Tunnel: down (enrolled; run `cmux vpn up`)"))
        } else {
            print(String(localized: "cli.vpn.status.notSetUp", defaultValue: "Tunnel: not set up (run `cmux vpn up`)"))
        }
        if let path = response["config_path"] as? String, configPresent {
            let format = String(localized: "cli.vpn.status.config", defaultValue: "Config: %@")
            print(String(format: format, path))
        }
        let backendFormat = String(localized: "cli.vpn.status.backend", defaultValue: "Backend: %@")
        print(String(format: backendFormat, neAvailable ? "app-managed (NetworkExtension)" : "wg-quick"))
        if !neAvailable, Self.firstExecutable(Self.wgQuickCandidates) == nil {
            print(String(
                localized: "cli.vpn.status.wgQuickMissing",
                defaultValue: "wg-quick is not installed. Install with: brew install wireguard-tools"
            ))
        }
    }

    private func runVPNRevoke(client: SocketClient, jsonOutput: Bool) throws {
        // Best effort: take the interface down first so a revoked config isn't
        // left routing traffic into a tunnel the server already deleted.
        let status = try? client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        if (status?["interface_up"] as? Bool) == true,
           let configPath = status?["config_path"] as? String,
           let wgQuick = Self.firstExecutable(Self.wgQuickCandidates) {
            _ = runInteractiveProcess(
                executablePath: "/usr/bin/sudo",
                arguments: [wgQuick, "down", configPath]
            )
        }
        let response = try client.sendV2(method: "vm.tunnel_revoke", responseTimeout: 60)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print(String(localized: "cli.vpn.revoked", defaultValue: "This Mac is unenrolled from your Cloud VM network."))
        }
    }

    private func printVPNAddresses(_ response: [String: Any]) {
        let address = (response["address_v4"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (response["address_v6"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let address {
            let format = String(
                localized: "cli.vpn.address",
                defaultValue: "Your address on the network: %@"
            )
            print(String(format: format, address))
        }
    }

    private static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run a subprocess on the caller's own tty (sudo needs it for its
    /// password prompt; wg-quick's output is the user's feedback).
    ///
    /// Foundation's `Process` puts the child in its own process group, so a
    /// child that reads the tty (sudo's password prompt) is stopped with
    /// SIGTTIN and the command looks hung. Foreground the child's group for
    /// its lifetime and restore ours after — the same dance the feed TUI does.
    func runInteractiveProcess(executablePath: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        let originalForegroundProcessGroup = tcgetpgrp(STDIN_FILENO)
        var didForegroundChild = false
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("could not run \(executablePath): \(error.localizedDescription)\n".utf8))
            return 1
        }
        if originalForegroundProcessGroup > 0 {
            let childProcessGroup = getpgid(process.processIdentifier)
            if childProcessGroup > 0 && childProcessGroup != originalForegroundProcessGroup {
                if (try? setTerminalForegroundProcessGroup(childProcessGroup)) != nil {
                    // The child may already have stopped on SIGTTIN before we
                    // foregrounded it; wake it so the prompt appears.
                    _ = Darwin.kill(-childProcessGroup, SIGCONT)
                    didForegroundChild = true
                }
            }
        }
        defer {
            if didForegroundChild {
                try? setTerminalForegroundProcessGroup(originalForegroundProcessGroup)
            }
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
