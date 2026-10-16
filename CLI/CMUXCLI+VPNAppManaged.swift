import Foundation

/// `cmux vpn` on builds whose app manages the tunnel itself (a signed
/// NetworkExtension system extension). No sudo, no wg-quick, no Homebrew: the
/// verbs become thin shims over the app's `vm.tunnel_*` socket verbs. The
/// tunnel is a system-wide route for *other* apps on this Mac; cmux's own
/// terminals, Ports, and Desktop use the user-space hub and never need it, so
/// `cmux vpn up` is the only thing that ever asks macOS to load the extension.
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
        let enrolled = (before["config_present"] as? Bool) ?? false
        if !jsonOutput, !wasUp {
            // Say what is about to happen before macOS asks anything: the
            // first start installs a system extension and a VPN configuration,
            // and the OS dialog that follows explains neither. A Mac that
            // already enrolled is only turning an installed tunnel back on.
            if enrolled {
                print(String(
                    localized: "cli.vpn.appManaged.explainReconnect",
                    defaultValue: "This turns the cmux Cloud Tunnel back on, so every app on this Mac can reach your Cloud VM network. cmux itself does not need it: terminals, Ports, and Desktop use the built-in user-space tunnel."
                ))
            } else {
                print(String(
                    localized: "cli.vpn.appManaged.explain",
                    defaultValue: "This installs the cmux Cloud Tunnel network extension and a macOS VPN configuration named “cmux Cloud”, so every app on this Mac can reach your Cloud VM network. cmux itself does not need it: terminals, Ports, and Desktop use the built-in user-space tunnel. The first time, macOS asks you to allow the extension in System Settings › General › Login Items & Extensions."
                ))
            }
            print(String(
                localized: "cli.vpn.appManaged.bringingUp",
                defaultValue: "Bringing the tunnel up (app-managed, no sudo needed)…"
            ))
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
            defaultValue: "Pinned up until `cmux vpn down`. Quitting cmux or signing out also takes it down."
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
        // The app refuses to start (Cloud Machines off, or no machine yet):
        // say why instead of promising an automatic start.
        if state == "off", let refusal = response["start_refusal_message"] as? String, !refusal.isEmpty {
            let format = String(localized: "cli.vpn.status.unavailable", defaultValue: "Tunnel: unavailable (%@)")
            print(String(format: format, refusal))
            return
        }
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
                    defaultValue: "Tunnel: down (`cmux vpn up` gives other apps on this Mac a route to your Cloud VM network; cmux itself does not need it)"
                ))
            } else {
                print(String(
                    localized: "cli.vpn.status.notSetUpAppManaged",
                    defaultValue: "Tunnel: not set up (`cmux vpn up` enrolls this Mac and asks macOS to allow the cmux Cloud Tunnel extension; cmux itself does not need it)"
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
