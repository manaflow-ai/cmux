import CmuxFoundation
import Darwin
import Foundation

/// `cmux vpn` — the WireGuard tunnel between this Mac and the user's private
/// Cloud VM network.
///
/// Cloud machines live on one private network per account and open no public
/// inbound port, so their session daemons are reachable only through this
/// tunnel. The cmux app owns enrollment (keypair, device identity, the config
/// file at `~/.cmuxterm/wireguard/<interface>.conf`).
///
/// Two backends, one command; the socket response's `backend` field picks:
/// - **app-managed** (`network-extension`): the app runs the tunnel through its
///   signed system extension and starts it on demand when a Cloud machine is
///   opened, so these verbs are rarely needed. `up` pins it, `down` releases
///   it, no sudo involved (`CMUXCLI+VPNAppManaged.swift`).
/// - **wg-quick**: builds without that capability. `up` runs `sudo wg-quick up`
///   on the app-written config, because creating a utun and installing routes
///   needs root and `sudo` in the user's own terminal is the honest way to
///   ask. Requires `brew install wireguard-tools`.
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
        case "hosts":
            try runVPNHostsSync(client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "Usage: cmux vpn <up|down|status|revoke|hosts>")
        }
    }

    private func runVPNUp(client: SocketClient, jsonOutput: Bool) throws {
        // The app enrolls (idempotently) and writes the completed config; this
        // process never sees the private key except as bytes inside that
        // 0600 file it does not read.
        // Read-only first: on the app-managed backend the app enrolls as part
        // of starting the tunnel, so `vm.tunnel_config` here would enroll twice.
        let status = try client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        if Self.tunnelBackendIsAppManaged(status) {
            try runAppManagedVPNUp(client: client, jsonOutput: jsonOutput, status: status)
            return
        }
        let response = try client.sendV2(method: "vm.tunnel_config", responseTimeout: 120)
        guard let configPath = response["config_path"] as? String, !configPath.isEmpty else {
            throw CLIError(message: "The cmux app did not return a tunnel config. Update cmux and retry.")
        }
        let interfaceUp = (response["interface_up"] as? Bool) ?? false
        // Up, but with another enrollment's config (a different account on the
        // same Mac, or keys the server rotated): "already up" would leave every
        // private route dead, so the stale interface is replaced instead.
        let stale = (response["stale"] as? Bool) ?? false

        if interfaceUp, !stale {
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
            if interfaceUp {
                print(String(
                    localized: "cli.vpn.switching",
                    defaultValue: "The tunnel that is up was brought up for another enrollment (a different account, or older keys). Replacing it with this one (sudo will prompt for your password)…"
                ))
            } else {
                print(String(localized: "cli.vpn.bringingUp", defaultValue: "Bringing the tunnel up (sudo will prompt for your password)…"))
            }
        }
        if interfaceUp {
            let downStatus = runInteractiveProcess(
                executablePath: "/usr/bin/sudo",
                arguments: [wgQuick, "down", configPath]
            )
            guard downStatus == 0 else {
                throw CLIError(message: String(
                    localized: "cli.vpn.switchFailed",
                    defaultValue: "Could not switch the tunnel. Check the command output above, run `cmux vpn down`, then retry `cmux vpn up`."
                ))
            }
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
        // Tell the app which config is up now, so a later enrollment (another
        // account, rotated keys) is detected as stale instead of read as "up".
        // Best effort: the tunnel works either way; without the record the next
        // `vpn up` simply re-applies once.
        var appliedParams: [String: Any] = ["applied": true]
        if let digest = response["config_digest"] as? String { appliedParams["config_digest"] = digest }
        _ = try? client.sendV2(method: "vm.tunnel_applied", params: appliedParams, responseTimeout: 30)
        if jsonOutput {
            print(jsonString(["status": "up", "config_path": configPath, "changed": true, "switched": interfaceUp]))
        } else {
            print(String(localized: "cli.vpn.up", defaultValue: "Tunnel is up."))
            printVPNAddresses(response)
        }
        // Best-effort: the tunnel is already up and useful without this. sudo
        // caches the credential this process just used, so this rarely
        // reprompts.
        try? runVPNHostsSync(client: client, jsonOutput: jsonOutput, quiet: !jsonOutput, scope: response["interface_name"] as? String)
    }

    private func runVPNDown(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        if Self.tunnelBackendIsAppManaged(response) {
            try runAppManagedVPNDown(client: client, jsonOutput: jsonOutput, status: response)
            return
        }
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
        // Nothing is up now: clear the applied-config record (best effort).
        _ = try? client.sendV2(method: "vm.tunnel_applied", params: ["applied": false], responseTimeout: 30)
        if jsonOutput {
            print(jsonString(["status": "down", "changed": true]))
        } else {
            print(String(localized: "cli.vpn.down", defaultValue: "Tunnel is down."))
        }
    }

    /// `<machine>.internal` names for every machine this account owns, written
    /// into a cmux-managed block in `/etc/hosts` so they resolve system-wide
    /// (browser, curl, anything) whenever the tunnel is up. Idempotent: run it
    /// as often as you like, including right after `cmux vm new`.
    private func runVPNHostsSync(
        client: SocketClient,
        jsonOutput: Bool,
        quiet: Bool = false,
        clear: Bool = false,
        scope: String? = nil
    ) throws {
        // Each environment's tunnel publishes its own block: a dev build's
        // machines must never overwrite (or clear) the production block.
        let scope = try scope ?? (client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)["interface_name"] as? String)
        var entries: [CmuxInternalHostnames.Entry] = []
        if !clear {
            let response = try client.sendV2(method: "vm.list", responseTimeout: 30)
            let vms = (response["vms"] as? [[String: Any]]) ?? []
            for vm in vms {
                guard let id = vm["id"] as? String, !id.isEmpty else { continue }
                guard let address = vm["address"] as? [String: Any] else { continue }
                guard let ip = (address["ipv4"] as? String) ?? (address["ipv6"] as? String), !ip.isEmpty else { continue }
                let label = (vm["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                var hostnames = [CmuxInternalHostnames.hostname(id: id, label: nil)]
                if let label, !label.isEmpty {
                    let labeled = CmuxInternalHostnames.hostname(id: id, label: label)
                    if labeled != hostnames[0] { hostnames.append(labeled) }
                }
                entries.append(CmuxInternalHostnames.Entry(address: ip, hostnames: hostnames))
            }
        }

        let hostsPath = "/etc/hosts"
        let current = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        let body = CmuxInternalHostnames.renderBlockBody(entries)
        let updated = CmuxInternalHostnames.mergedHostsFile(current: current, body: body, scope: scope)
        guard updated != current else {
            if jsonOutput {
                print(jsonString(["hosts_changed": false, "machine_count": entries.count]))
            } else if !quiet {
                print(String(localized: "cli.vpn.hosts.upToDate", defaultValue: "Internal hostnames are already up to date."))
            }
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hosts-\(UUID().uuidString)", isDirectory: false)
        try updated.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if !quiet {
            print(String(
                localized: "cli.vpn.hosts.updating",
                defaultValue: "Updating /etc/hosts with your machines' internal names (sudo may prompt)…"
            ))
        }
        // One sudo invocation does the copy, ownership/mode, and cache flush,
        // so a cached credential from `vpn up`'s wg-quick call covers this too
        // instead of prompting a second time.
        let script = "cp '\(tempURL.path)' '\(hostsPath)' && chown root:wheel '\(hostsPath)' && chmod 644 '\(hostsPath)' && dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null || true"
        let status = runInteractiveProcess(executablePath: "/usr/bin/sudo", arguments: ["/bin/sh", "-c", script])
        guard status == 0 else {
            throw CLIError(message: "Updating /etc/hosts failed (exit \(status)). Check the output above.")
        }
        if jsonOutput {
            print(jsonString(["hosts_changed": true, "machine_count": entries.count]))
        } else if !quiet {
            let format = String(localized: "cli.vpn.hosts.updated", defaultValue: "Updated /etc/hosts for %d machine(s).")
            print(String(format: format, entries.count))
        }
    }

    private func runVPNStatus(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let interfaceUp = (response["interface_up"] as? Bool) ?? false
        let stale = (response["stale"] as? Bool) ?? false
        let configPresent = (response["config_present"] as? Bool) ?? false
        let neAvailable = Self.tunnelBackendIsAppManaged(response)
        if neAvailable {
            printAppManagedVPNState(response)
        } else if interfaceUp, stale {
            print(String(
                localized: "cli.vpn.status.stale",
                defaultValue: "Tunnel: up, but for a different enrollment (run `cmux vpn up` to switch it)"
            ))
        } else if interfaceUp {
            print(String(localized: "cli.vpn.status.up", defaultValue: "Tunnel: up"))
        } else if configPresent {
            print(String(localized: "cli.vpn.status.down", defaultValue: "Tunnel: down (enrolled; run `cmux vpn up`)"))
        } else {
            print(String(localized: "cli.vpn.status.notSetUp", defaultValue: "Tunnel: not set up (run `cmux vpn up`)"))
        }
        if let name = response["interface_name"] as? String, !name.isEmpty {
            // One tunnel per deployment: says which one this build owns.
            let format = String(localized: "cli.vpn.status.interface", defaultValue: "Interface: %@")
            print(String(format: format, name))
        }
        if let path = response["config_path"] as? String, configPresent {
            let format = String(localized: "cli.vpn.status.config", defaultValue: "Config: %@")
            print(String(format: format, path))
        }
        let backendFormat = String(localized: "cli.vpn.status.backend", defaultValue: "Backend: %@")
        print(String(format: backendFormat, neAvailable ? "app-managed (NetworkExtension)" : "wg-quick"))
        if neAvailable {
            print(String(
                localized: "cli.vpn.status.autoManaged",
                defaultValue: "The tunnel starts automatically when you open a Cloud machine and stops when no Cloud sessions remain."
            ))
        }
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
        // On the app-managed backend `vm.tunnel_revoke` stops the tunnel and
        // deletes the VPN configuration itself; only wg-quick needs sudo here.
        if let status, !Self.tunnelBackendIsAppManaged(status),
           (status["interface_up"] as? Bool) == true,
           let configPath = status["config_path"] as? String,
           let wgQuick = Self.firstExecutable(Self.wgQuickCandidates) {
            _ = runInteractiveProcess(
                executablePath: "/usr/bin/sudo",
                arguments: [wgQuick, "down", configPath]
            )
        }
        let response = try client.sendV2(method: "vm.tunnel_revoke", responseTimeout: 60)
        // This Mac can no longer reach anything on the network — every
        // `.internal` name it published is now unreachable regardless of
        // whether the machines behind them still exist — so clear the whole
        // block rather than leave dead entries. Best-effort — a failure here
        // must not turn a successful revoke into an error.
        try? runVPNHostsSync(client: client, jsonOutput: false, quiet: true, clear: true, scope: status?["interface_name"] as? String)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print(String(localized: "cli.vpn.revoked", defaultValue: "This Mac is unenrolled from your Cloud VM network."))
        }
    }

    func printVPNAddresses(_ response: [String: Any]) {
        // Enrollment answers carry address_v4/v6; status answers carry the
        // interface addresses parsed from the config on disk.
        let address = (response["address_v4"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (response["address_v6"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (response["addresses"] as? [String])?.first
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
