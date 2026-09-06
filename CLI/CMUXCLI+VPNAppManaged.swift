import Foundation

/// `cmux vpn` on builds whose app manages the tunnel itself (a signed
/// NetworkExtension system extension). No sudo, no wg-quick, no Homebrew: the
/// verbs become thin shims over the app's `vm.tunnel_*` socket verbs, and the
/// tunnel normally needs none of them because the app starts it when a Cloud
/// machine is opened and stops it when no Cloud sessions remain.
///
/// The socket response's `backend` field decides which path `cmux vpn` takes,
/// so one CLI build serves entitled and unentitled apps alike.
extension CMUXCLI {
    static let appManagedTunnelBackend = "network-extension"

    static func tunnelBackendIsAppManaged(_ response: [String: Any]) -> Bool {
        (response["backend"] as? String) == appManagedTunnelBackend
    }

    /// `cmux vpn up` on the app-managed backend: pin the tunnel up and wait for
    /// the outcome. Enrollment happens inside the app's start (once), so this
    /// takes the read-only status rather than a `vm.tunnel_config` answer. The
    /// first run on a Mac may block on the user allowing the extension in
    /// System Settings; the wait rides `vm.tunnel_wait`, which returns the
    /// moment the app sees the approval.
    func runAppManagedVPNUp(client: SocketClient, jsonOutput: Bool, status before: [String: Any]) throws {
        let wasUp = (before["interface_up"] as? Bool) ?? false
        if !jsonOutput {
            if !wasUp {
                print(String(
                    localized: "cli.vpn.appManaged.bringingUp",
                    defaultValue: "Bringing the tunnel up (app-managed, no sudo needed)…"
                ))
            }
        }
        var status = try client.sendV2(method: "vm.tunnel_up", responseTimeout: 130)
        if (status["tunnel_state"] as? String) == "awaiting-approval" {
            if !jsonOutput {
                print(String(
                    localized: "cli.vpn.appManaged.needsApproval",
                    defaultValue: "macOS needs your approval to load the cmux Cloud Tunnel extension. Open System Settings › General › Login Items & Extensions › Network Extensions, allow cmux, then return here (waiting up to 10 minutes)…"
                ))
            }
            status = try client.sendV2(
                method: "vm.tunnel_wait",
                params: ["timeout_seconds": 600],
                responseTimeout: 630
            )
        }
        let state = (status["tunnel_state"] as? String) ?? ""
        guard state == "up" else {
            let detail = (status["tunnel_error"] as? String) ?? state
            throw CLIError(message: """
                The cmux app could not bring the tunnel up (\(detail)).

                What to do:
                  Check `cmux vpn status`, then retry `cmux vpn up`. If macOS asked to allow a system extension, allow it in System Settings › General › Login Items & Extensions.
                """)
        }
        if jsonOutput {
            print(jsonString([
                "status": "up",
                "backend": Self.appManagedTunnelBackend,
                "config_path": (status["config_path"] as? String) ?? "",
                "changed": !wasUp,
                "pinned": (status["pinned"] as? Bool) ?? true,
            ]))
            return
        }
        if wasUp {
            print(String(localized: "cli.vpn.alreadyUp", defaultValue: "Tunnel is already up."))
        } else {
            print(String(localized: "cli.vpn.up", defaultValue: "Tunnel is up."))
        }
        printVPNAddresses(status)
        print(String(
            localized: "cli.vpn.appManaged.pinned",
            defaultValue: "Pinned up until `cmux vpn down`. Otherwise cmux starts the tunnel when you open a Cloud machine and stops it when no Cloud sessions remain."
        ))
    }

    /// `cmux vpn down` on the app-managed backend: release the pin and stop.
    func runAppManagedVPNDown(client: SocketClient, jsonOutput: Bool, status before: [String: Any]) throws {
        let wasUp = (before["interface_up"] as? Bool) ?? false
        _ = try client.sendV2(method: "vm.tunnel_down", responseTimeout: 70)
        if jsonOutput {
            print(jsonString(["status": "down", "backend": Self.appManagedTunnelBackend, "changed": wasUp]))
        } else if wasUp {
            print(String(localized: "cli.vpn.down", defaultValue: "Tunnel is down."))
        } else {
            print(String(localized: "cli.vpn.notUp", defaultValue: "Tunnel is not up."))
        }
    }

    /// The state lines of `cmux vpn status` on the app-managed backend.
    func printAppManagedVPNState(_ response: [String: Any]) {
        let state = (response["tunnel_state"] as? String) ?? "off"
        let configPresent = (response["config_present"] as? Bool) ?? false
        switch state {
        case "up":
            print(String(localized: "cli.vpn.status.up", defaultValue: "Tunnel: up"))
        case "starting", "stopping":
            print(String(localized: "cli.vpn.status.state.starting", defaultValue: "Tunnel: starting"))
        case "awaiting-approval":
            print(String(
                localized: "cli.vpn.status.state.awaitingApproval",
                defaultValue: "Tunnel: waiting for approval in System Settings › General › Login Items & Extensions"
            ))
        case "failed":
            let format = String(localized: "cli.vpn.status.state.failed", defaultValue: "Tunnel: failed (%@)")
            print(String(format: format, (response["tunnel_error"] as? String) ?? "unknown"))
        default:
            if configPresent {
                print(String(
                    localized: "cli.vpn.status.downAppManaged",
                    defaultValue: "Tunnel: down (starts automatically when you open a Cloud machine)"
                ))
            } else {
                print(String(
                    localized: "cli.vpn.status.notSetUpAppManaged",
                    defaultValue: "Tunnel: not set up (enrolls automatically when you open a Cloud machine)"
                ))
            }
        }
        if (response["pinned"] as? Bool) == true {
            print(String(
                localized: "cli.vpn.status.pinned",
                defaultValue: "Pinned up by `cmux vpn up`; run `cmux vpn down` to release."
            ))
        }
    }
}
