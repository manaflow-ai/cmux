// SSH machines: machines reached over the user's own OpenSSH, each a
// cmux-tui session in the sidebar (plans/cmux-next/data-model.md 1.1).
// Titles live in RemoteActions.xcstrings.

nonisolated enum RemoteActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        // Whose localhost a workspace's browser tabs reach: the person's own
        // choice, kept in personal state (plans/cmux-next/remote-localhost.md
        // 9). From a terminal it applies only after the person approves it in
        // the app, so the CLI waits for that answer; MCP never offers it.
        var setRemoteLocalhost = ActionDescriptor(
            id: "workspace.setRemoteLocalhost",
            title: String(localized: "action.workspace.setRemoteLocalhost", defaultValue: "Set Workspace Localhost…", table: "RemoteActions", bundle: .module),
            keywords: ["remote", "localhost", "loopback", "ssh", "cloud", "machine", "browser", "dev server"], category: .remote,
            symbol: "network", surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.remoteLocalhostChoice],
            targets: [.workspace], cliName: "workspace set-remote-localhost"
        )
        setRemoteLocalhost.waitsForResult = true
        return [
            ActionDescriptor(
                id: "remote.connect",
                title: String(localized: "action.remote.connect", defaultValue: "Connect to Machine…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "host", "server", "machine", "cmux-tui"], category: .remote, symbol: "cable.connector",
                surfaces: [.palette, .menu, .contextMenu],
                arguments: [CatalogArgument.destinationString, CatalogArgument.sessionString, CatalogArgument.binaryString,
                            CatalogArgument.stateDirString],
                cliName: "remote connect", mainMenu: .file
            ),
            // The one entry for every new device (plans/cmux-next/add-device-DESIGN.md): a computer on
            // your network, a computer that shows a code, or a new device. It hands off to Add Machine
            // or Add Server, which stay as its ways; CLI and MCP only open the card.
            ActionDescriptor(
                id: "device.add",
                title: String(localized: "action.device.add", defaultValue: "Add Device…", table: "RemoteActions", bundle: .module),
                keywords: ["device", "add", "computer", "phone", "iphone", "mac", "linux", "windows", "server", "machine",
                           "pair", "code", "tailscale", "tailnet", "network", "join", "enroll", "approve"],
                category: .remote, symbol: "ipad.and.iphone", surfaces: [.palette, .menu, .contextMenu],
                arguments: [CatalogArgument.addDeviceWay],
                cliName: "device add", mainMenu: .file
            ),
            // One click from a host name to a working agent machine (plans/cmux-next/add-machine-DESIGN.md):
            // the Add Machine card runs `cmux-tui acp host enroll`; a destination only fills it (Add starts it).
            // Add Device's "On your network" way; the sidebar menu offers Add Device instead.
            ActionDescriptor(
                id: "machine.add",
                title: String(localized: "action.machine.add", defaultValue: "Add Machine…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "host", "machine", "tailscale", "tailnet", "enroll", "agent", "peer", "acpmux"],
                category: .remote, symbol: "plus.rectangle.on.rectangle", surfaces: [.palette],
                arguments: [CatalogArgument.optionalDestination, CatalogArgument.optionalMachineName],
                cliName: "machine add",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // The same card's checklist for one SSH machine (`host doctor`), with Fix (`--fix`).
            ActionDescriptor(
                id: "machine.doctor",
                title: String(localized: "action.machine.doctor", defaultValue: "Check Machine", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "host", "machine", "doctor", "health", "check", "fix", "agent", "peer", "acpmux"],
                category: .remote, symbol: "stethoscope", surfaces: [.palette, .contextMenu], targets: [.machine],
                cliName: "machine doctor"
            ),
            ActionDescriptor(
                id: "remote.newGroup",
                title: String(localized: "action.remote.newGroup", defaultValue: "New Remote Group…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "host", "server", "group", "mac mini", "linux", "vm"], category: .remote, symbol: "rectangle.stack.badge.plus",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.destinationString],
                cliName: "remote new-group"
            ),
            ActionDescriptor(
                id: "remote.removeGroup",
                title: String(localized: "action.remote.removeGroup", defaultValue: "Remove Remote Group", table: "RemoteActions", bundle: .module),
                keywords: ["remote", "host", "group", "header", "list"], category: .remote, symbol: "rectangle.stack.badge.minus",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote remove-group"
            ),
            ActionDescriptor(
                id: "machine.reconnect",
                title: String(localized: "action.machine.reconnect", defaultValue: "Reconnect", table: "RemoteActions", bundle: .module),
                keywords: ["remote", "host", "server", "cloud", "connect", "retry", "offline"], category: .remote, symbol: "arrow.clockwise",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "machine reconnect"
            ),
            ActionDescriptor(
                id: "remote.newWorkspace",
                title: String(localized: "action.remote.newWorkspace", defaultValue: "New Workspace on Machine", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "host", "terminal"], category: .remote, symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote new-workspace", startsTerminal: true
            ),
            ActionDescriptor(
                id: "remote.openTerminalHere",
                title: String(localized: "action.remote.openTerminalHere", defaultValue: "Open Terminal on Machine Here…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "machine", "session", "terminal", "mixed"], category: .remote, symbol: "terminal",
                surfaces: [.palette, .keyboard, .contextMenu], arguments: [CatalogArgument.machineMachine, CatalogArgument.directionChoice.optional, CatalogArgument.cwdString.optional],
                targets: [.pane], cliName: "remote open-terminal-here", startsTerminal: true
            ),
            // `cmux open-remote <host>`: one idempotent verb (manaflow-ai/cmux#25092).
            ActionDescriptor(
                id: "remote.openRemote",
                title: String(localized: "action.remote.openRemote", defaultValue: "Open Remote Terminal", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "machine", "host", "open-remote", "split", "attach", "terminal"], category: .remote, symbol: "network",
                surfaces: [.palette], arguments: [
                    CatalogArgument.openRemoteHost, CatalogArgument.openRemoteSplit, CatalogArgument.cwdString.optional,
                    CatalogArgument.openRemoteCmd, CatalogArgument.nameString.optional, CatalogArgument.openRemoteLabel,
                    CatalogArgument.openRemoteAttach, CatalogArgument.openRemoteRatio, CatalogArgument.focusBool.optional,
                ],
                targets: [.pane], cliName: "open-remote", startsTerminal: true
            ),
            ActionDescriptor(
                id: "remote.reconnect",
                title: String(localized: "action.remote.reconnect", defaultValue: "Reconnect Machine", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "retry"], category: .remote, symbol: "arrow.clockwise",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote reconnect"
            ),
            ActionDescriptor(
                id: "remote.disconnect",
                title: String(localized: "action.remote.disconnect", defaultValue: "Disconnect Machine", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "offline"], category: .remote, symbol: "bolt.horizontal.circle",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote disconnect"
            ),
            ActionDescriptor(
                id: "remote.install",
                title: String(localized: "action.remote.install", defaultValue: "Install cmux-tui on Machine…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "update", "upgrade", "cmux-tui"], category: .remote, symbol: "arrow.down.circle",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote install", destructive: true
            ),
            setRemoteLocalhost,
            // The machine's raw SSH or install error (the sidebar header's
            // tooltip says it in a sentence), for a bug report or a search.
            ActionDescriptor(
                id: "remote.copyError",
                title: String(localized: "action.remote.copyError", defaultValue: "Copy SSH Error", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "error", "copy", "machine", "permission", "denied"], category: .remote,
                symbol: "exclamationmark.bubble", surfaces: [.palette, .contextMenu], targets: [.machine],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.clipboard),
                                               contextMenus: [ActionSurfaceCatalog.p(.sshMachine, .inspect, 300, folder: .copy)])
            ),
            ActionDescriptor(
                id: "remote.forget",
                title: String(localized: "action.remote.forget", defaultValue: "Forget Machine…", table: "RemoteActions", bundle: .module),
                keywords: ["ssh", "remote", "remove", "delete"], category: .remote, symbol: "trash",
                surfaces: [.palette, .contextMenu], targets: [.machine], cliName: "remote forget", destructive: true
            ),
            // DEV and NIGHTLY only: a remote browser tab (remote-tab.md r2)
            // from a loopback rb/1 host such as cmux-remote-browser-testhost.
            // Scripts reach it through `action.run`, the same path. The host
            // serves only a viewer with its secret: without `secretFile` the
            // tab shows the host's refusal (cx-erey).
            ActionDescriptor(
                id: "remote.openBrowserTab",
                title: String(localized: "action.remote.openBrowserTab", defaultValue: "Open Remote Browser Tab…", table: "RemoteActions", bundle: .module),
                keywords: ["remote", "browser", "tab", "rb", "stream", "chromium", "host"], category: .remote, symbol: "globe",
                surfaces: [.palette],
                arguments: [
                    ActionArgument(
                        name: "address",
                        title: String(localized: "argument.remote.hostAddress", defaultValue: "Host Address", table: "RemoteActions", bundle: .module),
                        kind: .string),
                    // A file that only this user can read, holding the host's
                    // per-launch secret on its first line. The tab record keeps
                    // the path, never the secret (RemoteBrowserSecretFile).
                    ActionArgument(
                        name: "secretFile",
                        title: String(localized: "argument.remote.secretFile", defaultValue: "Host Secret File", table: "RemoteActions", bundle: .module),
                        kind: .string, isRequired: false),
                ],
                isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            // DEV only: starts this build's remote browser host on a free
            // loopback port and opens a remote tab to it; closing the tab
            // stops the host (RemoteBrowserPages.openLocal).
            ActionDescriptor(
                id: "remote.openLocalBrowserTab",
                title: String(localized: "action.remote.openLocalBrowserTab", defaultValue: "Open Remote Browser Tab (Local Host)", table: "RemoteActions", bundle: .module),
                keywords: ["remote", "browser", "tab", "rb", "stream", "chromium", "host", "local", "loopback"], category: .remote, symbol: "globe",
                surfaces: [.palette],
                isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
        ]
    }
}

nonisolated extension CatalogArgument {
    /// Add Machine's host: the card opens on the field without it.
    static var optionalDestination: ActionArgument {
        ActionArgument(name: "destination", title: String(localized: "argument.destination", defaultValue: "SSH Destination", table: "RemoteActions", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// Which of Add Device's ways the card opens on; it picks one without it.
    static var addDeviceWay: ActionArgument {
        func way(_ value: String, _ title: String) -> ActionEnumCase { ActionEnumCase(value: value, title: title) }
        return ActionArgument(
            name: "way",
            title: String(localized: "argument.addDeviceWay", defaultValue: "Way", table: "RemoteActions", bundle: .module),
            kind: .enumeration([
                way("network", String(localized: "argument.value.addDeviceWay.network", defaultValue: "On Your Network", table: "RemoteActions", bundle: .module)),
                way("code", String(localized: "argument.value.addDeviceWay.code", defaultValue: "It Shows a Code", table: "RemoteActions", bundle: .module)),
                way("newDevice", String(localized: "argument.value.addDeviceWay.newDevice", defaultValue: "Set Up a New Device", table: "RemoteActions", bundle: .module)),
            ]),
            isRequired: false)
    }

    /// Add Machine's name for the machine; the short host without it.
    static var optionalMachineName: ActionArgument {
        ActionArgument(name: "name", title: String(localized: "argument.name", defaultValue: "Name", bundle: .module), kind: .string, isRequired: false)
    }

    /// `machine` (the workspace's machine), `thisMac`, or `setting`
    /// (follow `browser.remoteLocalhost`).
    static var remoteLocalhostChoice: ActionArgument {
        func choice(_ value: String, _ title: String) -> ActionEnumCase { ActionEnumCase(value: value, title: title) }
        return ActionArgument(
            name: "localhost",
            title: String(localized: "argument.remoteLocalhost", defaultValue: "Localhost Target", table: "RemoteActions", bundle: .module),
            kind: .enumeration([
                choice("machine", String(localized: "argument.value.remoteLocalhost.machine", defaultValue: "The Workspace's Machine", table: "RemoteActions", bundle: .module)),
                choice("thisMac", String(localized: "argument.value.remoteLocalhost.thisMac", defaultValue: "This Mac", table: "RemoteActions", bundle: .module)),
                choice("setting", String(localized: "argument.value.remoteLocalhost.setting", defaultValue: "Follow Settings", table: "RemoteActions", bundle: .module)),
            ]))
    }
}
