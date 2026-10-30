// A Cloud machine's ports for the CLI, MCP and the palette (audit group H):
// `cmux cloud open-browser`, `port-list`, `port-forward`, `port-close` and
// `machine-link`. Titles live in CloudPortActions.xcstrings; the handlers are
// CloudHandlers+Browser.swift. Each row declares its own surfaces: the CLI
// verb, and (but for machine-link) a row in the machine menu's Connection folder.

nonisolated enum CloudPortActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var actions: [ActionDescriptor] = [
            ActionDescriptor(
                id: "cloudOpenBrowser",
                title: String(localized: "action.cloudOpenBrowser", defaultValue: "Open Machine Port in Browser…", table: "CloudPortActions", bundle: .module),
                description: "Opens --port N (and --path, default /) of the machine (--target machine:<id>) in a Chromium tab and returns url and surface_id; on the classic Cloud link the tab opens in the machine's workspace (workspace_id) and its localhost is the machine's. A tab not shown within 15 s answers pending: true.",
                keywords: ["vm", "cloud", "browser", "port", "localhost", "preview", "web"], category: .cloud, symbol: "safari",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.portInt, CatalogArgument.optionalPathString],
                targets: [.machine], cliName: "cloud open-browser", surfacePlan: plan(rank: 211)
            ),
            ActionDescriptor(
                id: "cloudPortList",
                title: String(localized: "action.cloudPortList", defaultValue: "List Forwarded Machine Ports", table: "CloudPortActions", bundle: .module),
                description: "Lists the machine's (--target machine:<id>) ports forwarded to this Mac: forwards, each with port, local_port, url and state. Only machines on the Cloud app server link keep forwards; on the classic link use `cmux cloud open-browser --target machine:<id> --port <port>`.",
                keywords: ["vm", "cloud", "port", "forward", "list"], category: .cloud, symbol: "list.bullet",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "cloud port-list", surfacePlan: plan(rank: 212)
            ),
            ActionDescriptor(
                id: "cloudPortForward",
                title: String(localized: "action.cloudPortForward", defaultValue: "Forward Machine Port…", table: "CloudPortActions", bundle: .module),
                description: "Forwards --port N of the machine (--target machine:<id>) to a port on this Mac and returns local_port, url (http://127.0.0.1:<local_port>/) and state. Close it with `cmux cloud port-close --target machine:<id> --port <port>`. Cloud app server link only.",
                keywords: ["vm", "cloud", "port", "forward", "tunnel", "localhost"], category: .cloud, symbol: "arrow.left.arrow.right",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.portInt], targets: [.machine],
                cliName: "cloud port-forward", surfacePlan: plan(rank: 213)
            ),
            ActionDescriptor(
                id: "cloudPortClose",
                title: String(localized: "action.cloudPortClose", defaultValue: "Close Forwarded Machine Port…", table: "CloudPortActions", bundle: .module),
                description: "Stops forwarding --port N of the machine (--target machine:<id>) to this Mac and returns closed: true; a port with no forward is refused. `cmux cloud port-list --target machine:<id>` lists the forwards.",
                keywords: ["vm", "cloud", "port", "forward", "close", "stop"], category: .cloud, symbol: "xmark.circle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.portInt], targets: [.machine],
                cliName: "cloud port-close", surfacePlan: plan(rank: 214)
            ),
            // Copy Machine Link's value for a caller with no clipboard: it answers the URL.
            ActionDescriptor(
                id: "cloudMachineLink",
                title: String(localized: "action.cloudMachineLink", defaultValue: "Get Machine Link…", table: "CloudPortActions", bundle: .module),
                description: "Returns the machine's (--target machine:<id>) link instead of copying it: machine_id, target and its private address. With --port N, also private_url and the provider's url and open_url for that port.",
                keywords: ["vm", "cloud", "link", "url", "port"], category: .cloud, symbol: "link",
                surfaces: [.palette], arguments: [optionalPort], targets: [.machine],
                // The machine menu's Copy Machine Link is its GUI form.
                cliName: "cloud machine-link", surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .duplicateOfDefault)
            ),
        ]
        // A CLI or agent run answers with the URL, the forward or the new tab (CloudHandlers+Browser.swift).
        for index in actions.indices { actions[index].waitsForResult = true }
        return actions
    }

    /// The CLI verb, and a row in the machine menu's Connection folder.
    static func plan(rank: Int) -> ActionSurfacePlan {
        ActionSurfacePlan(cli: .offered, contextMenus: [ActionSurfaceCatalog.p(.cloudMachine, .connection, rank, folder: .connection)])
    }

    /// `machine-link` without `--port` answers the machine's own links.
    static var optionalPort: ActionArgument {
        ActionArgument(name: "port", title: String(localized: "argument.port", defaultValue: "Port", bundle: .module), kind: .int(1...65535),
                       isRequired: false)
    }
}
