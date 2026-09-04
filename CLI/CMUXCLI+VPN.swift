import Foundation

/// Controls the browser Network Extension tunnel. Terminal and metadata links
/// use the separate user-space WireGuard hub and do not need this command.
extension CMUXCLI {
    func runVPNCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "status"
        switch subcommand {
        case "up", "on":
            try runVPNUp(client: client, jsonOutput: jsonOutput)
        case "down", "off":
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
        let status = try client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        guard Self.tunnelBackendIsAppManaged(status) else {
            throw CLIError(message: "This cmux build has no signed Network Extension. Browser VPN access is unavailable.")
        }
        try runAppManagedVPNUp(client: client, jsonOutput: jsonOutput, status: status)
    }

    private func runVPNDown(client: SocketClient, jsonOutput: Bool) throws {
        let status = try client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        guard Self.tunnelBackendIsAppManaged(status) else {
            throw CLIError(message: "This cmux build has no signed Network Extension. No browser VPN is running.")
        }
        try runAppManagedVPNDown(client: client, jsonOutput: jsonOutput, status: status)
    }

    private func runVPNStatus(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "vm.tunnel_status", responseTimeout: 30)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let terminal = response["terminal_tunnel"] as? [String: Any]
        let terminalRunning = (terminal?["hub_running"] as? Bool) ?? false
        print("Terminal tunnel: \(terminalRunning ? "up" : "idle") (user-space WireGuard)")
        if Self.tunnelBackendIsAppManaged(response) {
            printAppManagedVPNState(response)
            print("Browser backend: Network Extension")
        } else {
            print("Browser tunnel: unavailable in this build")
            print("Browser backend: unavailable")
        }
    }

    private func runVPNRevoke(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "vm.tunnel_revoke", responseTimeout: 60)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print(String(localized: "cli.vpn.revoked", defaultValue: "This Mac can no longer access your Cloud VM network."))
        }
    }

    func printVPNAddresses(_ response: [String: Any]) {
        let address = (response["address_v4"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (response["address_v6"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (response["addresses"] as? [String])?.first
        if let address {
            let format = String(localized: "cli.vpn.address", defaultValue: "Your address on the network: %@")
            print(String(format: format, address))
        }
    }
}
