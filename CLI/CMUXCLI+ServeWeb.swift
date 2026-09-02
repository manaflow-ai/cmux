import Foundation

extension CMUXCLI {
    /// Controls the opt-in Mac browser bridge. The bridge owns the listener and
    /// grant state in the app; this command is only a local v2 control client.
    func runServeWebCommand(
        commandArgs rawArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        var args = rawArgs
        let subcommand: String
        if let first = args.first, !first.hasPrefix("--") {
            subcommand = first.lowercased()
            args.removeFirst()
        } else {
            subcommand = "start"
        }

        switch subcommand {
        case "start", "serve":
            let bind = optionValue(args, name: "--bind")
                ?? optionValue(args, name: "--address")
                ?? "127.0.0.1"
            let port = try webPort(optionValue(args, name: "--port"))
            let label = optionValue(args, name: "--label")
            let start = try client.sendV2(
                method: "web.bridge.start",
                params: ["address": bind, "port": port]
            )
            let grant = try client.sendV2(
                method: "web.bridge.grant.create",
                params: label.map { ["label": $0] } ?? [:]
            )
            var payload = start
            payload["grant"] = grant["grant"] ?? NSNull()
            payload["token"] = grant["token"] ?? NSNull()
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            let address = (start["address"] as? String) ?? bind
            let boundPort = (start["port"] as? NSNumber)?.intValue
                ?? (start["port"] as? Int)
                ?? port
            let endpointHost = address.contains(":") ? "[\(address)]" : address
            let unavailable = String(
                localized: "cli.serveWeb.unavailable",
                defaultValue: "(unavailable)"
            )
            print(String(
                localized: "cli.serveWeb.listening",
                defaultValue: "cmux web client listening"
            ))
            print("  \(String(localized: "cli.serveWeb.endpointLabel", defaultValue: "endpoint")): ws://\(endpointHost):\(boundPort)/cmux")
            print("  \(String(localized: "cli.serveWeb.protocolLabel", defaultValue: "protocol")): cmux.web/1")
            print("  \(String(localized: "cli.serveWeb.tokenLabel", defaultValue: "token")):    \(grant["token"] as? String ?? unavailable)")
            let grantID = (grant["grant"] as? [String: Any])?["id"] as? String ?? "<grant-id>"
            print("  \(String(localized: "cli.serveWeb.revokeLabel", defaultValue: "revoke")):   cmux serve-web revoke \(grantID)")
            print(String(
                localized: "cli.serveWeb.trustedClientHint",
                defaultValue: "  safety:   paste this token only into a trusted cmux web client"
            ))
            if address.hasPrefix("100.") {
                print(String(
                    localized: "cli.serveWeb.secureProxyHint",
                    defaultValue: "  secure:   HTTPS-hosted pages need a private TLS proxy (for example: tailscale serve)"
                ))
            }

        case "status":
            let response = try client.sendV2(method: "web.bridge.status")
            if jsonOutput {
                print(jsonString(response))
            } else {
                let running = (response["running"] as? Bool) == true
                let address = (response["address"] as? String) ?? "-"
                let port = (response["port"] as? NSNumber)?.intValue ?? 0
                let endpointHost = address.contains(":") ? "[\(address)]" : address
                let runningLabel = String(
                    localized: "cli.serveWeb.running",
                    defaultValue: "running"
                )
                let stoppedLabel = String(
                    localized: "cli.serveWeb.stopped",
                    defaultValue: "stopped"
                )
                print(running ? "\(runningLabel) ws://\(endpointHost):\(port)/cmux" : stoppedLabel)
                if let grants = response["grants"] as? [[String: Any]] {
                    let grantsLabel = String(
                        localized: "cli.serveWeb.grantsLabel",
                        defaultValue: "grants"
                    )
                    print("\(grantsLabel): \(grants.count)")
                    for grant in grants {
                        let id = (grant["id"] as? String) ?? "?"
                        let label = (grant["label"] as? String) ?? String(
                            localized: "webClientBridge.defaultGrantLabel",
                            defaultValue: "Browser client"
                        )
                        let active = (grant["active"] as? Bool) == true
                            ? String(localized: "cli.serveWeb.active", defaultValue: "active")
                            : String(localized: "cli.serveWeb.revoked", defaultValue: "revoked")
                        let connections = (grant["connection_count"] as? NSNumber)?.intValue ?? 0
                        let connectionsLabel = String(
                            localized: "cli.serveWeb.connectionsLabel",
                            defaultValue: "connections"
                        )
                        print("  \(id)  \(label)  \(active)  \(connectionsLabel)=\(connections)")
                    }
                }
            }

        case "pair", "grant", "create":
            let label = optionValue(args, name: "--label")
            let response = try client.sendV2(
                method: "web.bridge.grant.create",
                params: label.map { ["label": $0] } ?? [:]
            )
            if jsonOutput {
                print(jsonString(response))
            } else {
                let unavailable = String(
                    localized: "cli.serveWeb.unavailable",
                    defaultValue: "(unavailable)"
                )
                print("\(String(localized: "cli.serveWeb.tokenLabel", defaultValue: "token")): \(response["token"] as? String ?? unavailable)")
                if let grant = response["grant"] as? [String: Any],
                   let id = grant["id"] as? String {
                    print("\(String(localized: "cli.serveWeb.grantLabel", defaultValue: "grant")): \(id)")
                }
            }

        case "grants", "list":
            let response = try client.sendV2(method: "web.bridge.grant.list")
            if jsonOutput {
                print(jsonString(response))
            } else if let grants = response["grants"] as? [[String: Any]], !grants.isEmpty {
                for grant in grants {
                    let id = (grant["id"] as? String) ?? "?"
                    let label = (grant["label"] as? String) ?? String(
                        localized: "webClientBridge.defaultGrantLabel",
                        defaultValue: "Browser client"
                    )
                    let active = (grant["active"] as? Bool) == true
                        ? String(localized: "cli.serveWeb.active", defaultValue: "active")
                        : String(localized: "cli.serveWeb.revoked", defaultValue: "revoked")
                    print("\(id)\t\(label)\t\(active)")
                }
            } else {
                print(String(
                    localized: "cli.serveWeb.noGrants",
                    defaultValue: "No browser grants"
                ))
            }

        case "revoke", "remove":
            let rawID = optionValue(args, name: "--id") ?? args.first
            guard let rawID, let id = UUID(uuidString: rawID) else {
                throw CLIError(message: String(
                    localized: "cli.serveWeb.revokeUsage",
                    defaultValue: "Usage: cmux serve-web revoke <grant-id>"
                ))
            }
            let response = try client.sendV2(
                method: "web.bridge.grant.revoke",
                params: ["grant_id": id.uuidString]
            )
            if jsonOutput { print(jsonString(response)) }
            else {
                print("\(String(localized: "cli.serveWeb.revokedGrantLabel", defaultValue: "Revoked browser grant")): \(id.uuidString)")
            }

        case "stop":
            let response = try client.sendV2(method: "web.bridge.stop")
            if jsonOutput { print(jsonString(response)) }
            else {
                print(String(
                    localized: "cli.serveWeb.stopComplete",
                    defaultValue: "cmux web client stopped"
                ))
            }

        default:
            throw CLIError(message: String(
                localized: "cli.serveWeb.usage",
                defaultValue: "Usage: cmux serve-web [start|status|pair|grants|revoke|stop] [options]"
            ))
        }
    }

    private func webPort(_ raw: String?) throws -> Int {
        guard let raw else { return 7683 }
        guard let port = Int(raw), (0 ... 65535).contains(port) else {
            throw CLIError(message: String(
                localized: "cli.serveWeb.invalidPort",
                defaultValue: "--port must be between 0 and 65535"
            ))
        }
        return port
    }
}
