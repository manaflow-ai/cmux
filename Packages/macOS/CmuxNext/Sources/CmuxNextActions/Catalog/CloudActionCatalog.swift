// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum CloudActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var actions: [ActionDescriptor] = [
            ActionDescriptor(
                id: "newCloudWorkspace",
                title: String(localized: "action.newCloudWorkspace", defaultValue: "New Cloud Workspace", bundle: .module),
                keywords: ["vm", "remote", "create"], defaultShortcut: Shortcut("y", modifiers: [.command, .shift]),
                category: .cloud, symbol: "cloud", surfaces: [.keyboard, .menu, .contextMenu], targets: [.machine],
                cliName: "cloud new-workspace", mainMenu: .file
            ),
            ActionDescriptor(
                id: "newCloudMachine",
                title: String(localized: "action.newCloudMachine", defaultValue: "New Cloud Machine…", bundle: .module),
                keywords: ["vm", "remote", "create"],
                category: .cloud, symbol: "server.rack", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                cliName: "cloud new-machine", mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.cloud.fork",
                title: String(localized: "action.palette.cloud.fork", defaultValue: "Fork Cloud Machine", bundle: .module),
                keywords: ["vm", "clone"], category: .cloud, symbol: "arrow.triangle.branch", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud fork-machine"
            ),
            ActionDescriptor(
                id: "palette.cloud.snapshot",
                title: String(localized: "action.palette.cloud.snapshot", defaultValue: "Snapshot Cloud Machine", bundle: .module),
                keywords: ["vm", "backup"], category: .cloud, symbol: "camera.aperture", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud snapshot-machine"
            ),
            ActionDescriptor(
                id: "palette.cloud.restore",
                title: String(localized: "action.palette.cloud.restore", defaultValue: "Restore Cloud Machine…", bundle: .module),
                keywords: ["vm", "snapshot"], category: .cloud, symbol: "clock.arrow.2.circlepath",
                surfaces: [.palette], requires: [.cloudWorkspace], arguments: [CatalogArgument.snapshotString],
                targets: [.machine], cliName: "cloud restore-machine"
            ),
            ActionDescriptor(
                id: "palette.cloud.promoteTemplate",
                title: String(localized: "action.palette.cloud.promoteTemplate", defaultValue: "Promote Machine to Template", bundle: .module),
                keywords: ["vm", "template"], category: .cloud, symbol: "star.square", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud promote-machine-to-template"
            ),
            ActionDescriptor(
                id: "palette.cloud.status",
                title: String(localized: "action.palette.cloud.status", defaultValue: "Cloud Machine Status", bundle: .module),
                keywords: ["vm", "health"], category: .cloud, symbol: "waveform.path.ecg", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud machine-status"
            ),
            ActionDescriptor(
                id: "palette.cloud.ports",
                title: String(localized: "action.palette.cloud.ports", defaultValue: "Cloud Machine Ports", bundle: .module),
                keywords: ["vm", "forward"], category: .cloud, symbol: "network", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud machine-ports"
            ),
            ActionDescriptor(
                id: "palette.cloud.tools",
                title: String(localized: "action.palette.cloud.tools", defaultValue: "Cloud Machine Tools", bundle: .module),
                keywords: ["vm"], category: .cloud, symbol: "wrench.and.screwdriver", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud machine-tools"
            ),
            ActionDescriptor(
                id: "palette.cloud.handoff",
                title: String(localized: "action.palette.cloud.handoff", defaultValue: "Hand Off Cloud Machine", bundle: .module),
                keywords: ["vm", "share"], category: .cloud, symbol: "hand.raised", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud hand-off-machine"
            ),
            // Move to Cloud (cmuxterm-hq#1874 slice 3): the palette, the tab and chat
            // right-click menus and `cmux cloud move` run this one action on a chat tab.
            ActionDescriptor(
                id: "cloudMove",
                title: String(localized: "action.cloudMove", defaultValue: "Move to Cloud", bundle: .module),
                keywords: ["vm", "cloud", "move", "chat", "agent", "remote", "sync"], category: .cloud,
                symbol: "icloud.and.arrow.up", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.optionalPathString, CatalogArgument.optionalMachine], targets: [.tab],
                cliName: "cloud move"
            ),
            // Bring Back Local (cmuxterm-hq#1874 slice 4): the reverse, on a Cloud chat tab that
            // a move from this Mac put there.
            ActionDescriptor(
                id: "cloudBringBack",
                title: String(localized: "action.cloudBringBack", defaultValue: "Bring Back Local", bundle: .module),
                keywords: ["vm", "cloud", "move", "back", "local", "chat", "agent", "sync"], category: .cloud,
                symbol: "icloud.and.arrow.down", surfaces: [.palette, .contextMenu], targets: [.tab],
                cliName: "cloud bring-back"
            ),
            ActionDescriptor(
                id: "cloudSSH",
                title: String(localized: "action.cloudSSH", defaultValue: "Open Cloud SSH Terminal", bundle: .module),
                keywords: ["vm", "cloud", "ssh", "terminal"], category: .cloud, symbol: "terminal",
                surfaces: [.palette, .contextMenu], targets: [.machine],
                cliName: "cloud ssh", startsTerminal: true
            ),
            ActionDescriptor(
                id: "cloudExec",
                title: String(localized: "action.cloudExec", defaultValue: "Run Command on Cloud Machine…", bundle: .module),
                keywords: ["vm", "cloud", "exec", "command"], category: .cloud, symbol: "terminal.fill",
                surfaces: [.palette], requires: [.cloudWorkspace], arguments: [CatalogArgument.commandString], targets: [.machine],
                cliName: "cloud exec", startsTerminal: true
            ),
            // One click on a machine: this Mac's git identity, and a gh sign-in the person approves
            // in their browser (device flow); no token leaves the Mac (CloudGitHubSetup).
            ActionDescriptor(
                id: "cloudSetupGitHub",
                title: String(localized: "action.cloudSetupGitHub", defaultValue: "Set Up GitHub on This Machine", bundle: .module),
                keywords: ["vm", "cloud", "github", "gh", "git", "login", "sign in", "identity"], category: .cloud,
                symbol: "person.badge.key", surfaces: [.palette, .contextMenu], targets: [.machine],
                cliName: "cloud setup-github"
            ),
            ActionDescriptor(
                id: "cloudFilesList",
                title: String(localized: "action.cloudFilesList", defaultValue: "List Cloud Files…", bundle: .module),
                keywords: ["vm", "cloud", "files", "directory", "ls"], category: .cloud, symbol: "folder",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], targets: [.machine],
                cliName: "cloud files-list"
            ),
            ActionDescriptor(
                id: "cloudFileRead",
                title: String(localized: "action.cloudFileRead", defaultValue: "Read Cloud File…", bundle: .module),
                keywords: ["vm", "cloud", "files", "read"], category: .cloud, symbol: "doc.text",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], targets: [.machine],
                cliName: "cloud file-read"
            ),
            ActionDescriptor(
                id: "cloudFileWrite",
                title: String(localized: "action.cloudFileWrite", defaultValue: "Write Cloud File…", bundle: .module),
                keywords: ["vm", "cloud", "files", "write"], category: .cloud, symbol: "square.and.pencil",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString, CatalogArgument.contentsString], targets: [.machine],
                cliName: "cloud file-write"
            ),
            ActionDescriptor(
                id: "cloudFileMkdir",
                title: String(localized: "action.cloudFileMkdir", defaultValue: "Create Cloud Directory…", bundle: .module),
                keywords: ["vm", "cloud", "files", "mkdir"], category: .cloud, symbol: "folder.badge.plus",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], targets: [.machine],
                cliName: "cloud file-mkdir"
            ),
            ActionDescriptor(
                id: "cloudFileRemove",
                title: String(localized: "action.cloudFileRemove", defaultValue: "Remove Cloud File…", bundle: .module),
                keywords: ["vm", "cloud", "files", "rm"], category: .cloud, symbol: "trash",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString, CatalogArgument.confirmBool], targets: [.machine],
                cliName: "cloud file-remove", destructive: true
            ),
            ActionDescriptor(
                id: "cloudFileStat",
                title: String(localized: "action.cloudFileStat", defaultValue: "Cloud File Details…", bundle: .module),
                keywords: ["vm", "cloud", "files", "stat"], category: .cloud, symbol: "info.circle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], targets: [.machine],
                cliName: "cloud file-stat"
            ),
            ActionDescriptor(
                id: "cloudPrepareSCP",
                title: String(localized: "action.cloudPrepareSCP", defaultValue: "Prepare Cloud File Transfer…", bundle: .module),
                keywords: ["vm", "cloud", "files", "scp", "ssh"], category: .cloud, symbol: "arrow.up.arrow.down",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.publicKeyString], targets: [.machine],
                cliName: "cloud prepare-scp"
            ),
            ActionDescriptor(id: "cloudTunnelAttach", title: String(localized: "action.cloudTunnelAttach", defaultValue: "Attach Cloud Tunnel Network", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "tunnel", "network"], category: .cloud, symbol: "link", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], cliName: "cloud tunnel-attach"),
            ActionDescriptor(id: "cloudTunnelDetach", title: String(localized: "action.cloudTunnelDetach", defaultValue: "Detach Cloud Tunnel Network", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "tunnel", "network"], category: .cloud, symbol: "scissors", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], cliName: "cloud tunnel-detach"),
            ActionDescriptor(id: "cloudTunnelRotateKey", title: String(localized: "action.cloudTunnelRotateKey", defaultValue: "Rotate Cloud Tunnel Key", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "tunnel", "key"], category: .cloud, symbol: "key", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.publicKeyString], cliName: "cloud tunnel-rotate-key"),
            ActionDescriptor(id: "cloudNetworkList", title: String(localized: "action.cloudNetworkList", defaultValue: "List Cloud Networks", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "network", "vpc"], category: .cloud, symbol: "network", surfaces: [.palette, .contextMenu], cliName: "cloud network-list"),
            ActionDescriptor(id: "cloudFirewallList", title: String(localized: "action.cloudFirewallList", defaultValue: "List Cloud Firewall Rules", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "firewall", "network"], category: .cloud, symbol: "shield", surfaces: [.palette, .contextMenu], cliName: "cloud firewall-list"),
            ActionDescriptor(id: "cloudFirewallGet", title: String(localized: "action.cloudFirewallGet", defaultValue: "Get Cloud Firewall Rule", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "firewall", "network"], category: .cloud, symbol: "shield.checkered", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], cliName: "cloud firewall-get"),
            ActionDescriptor(id: "cloudFirewallCreate", title: String(localized: "action.cloudFirewallCreate", defaultValue: "Create Cloud Firewall Rule", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "firewall", "network"], category: .cloud, symbol: "shield.lefthalf.filled", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], cliName: "cloud firewall-create"),
            ActionDescriptor(id: "cloudFirewallDelete", title: String(localized: "action.cloudFirewallDelete", defaultValue: "Delete Cloud Firewall Rule", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "firewall", "network"], category: .cloud, symbol: "shield.slash", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString, CatalogArgument.confirmBool], cliName: "cloud firewall-delete", destructive: true),
            ActionDescriptor(id: "cloudDomainList", title: String(localized: "action.cloudDomainList", defaultValue: "List Cloud Domains", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "domain", "dns", "verify"], category: .cloud, symbol: "globe", surfaces: [.palette], cliName: "cloud domain-list"),
            ActionDescriptor(id: "cloudPublicationList", title: String(localized: "action.cloudPublicationList", defaultValue: "List Cloud Publications", table: "ActionCatalog", bundle: .module), keywords: ["cloud", "domain", "publication", "tls"], category: .cloud, symbol: "globe.americas", surfaces: [.palette], cliName: "cloud publication-list"),
            // Read only: a CLI or agent run answers the app's own machine list (the sidebar's
            // Cloud machines) as `result`; a person's run shows the Cloud sidebar.
            ActionDescriptor(
                id: "cloudListMachines",
                title: String(localized: "action.cloudListMachines", defaultValue: "List Cloud Machines", bundle: .module),
                keywords: ["vm", "cloud", "machines", "list", "inventory"], category: .cloud, symbol: "list.bullet.rectangle",
                surfaces: [.palette], cliName: "cloud list-machines"
            ),
            ActionDescriptor(
                id: "cloudNewTerminal",
                // It makes a workspace (with a terminal), so its title says so; `--workspace <id>` adds
                // a terminal tab to that workspace of the machine instead. The CLI name stays for scripts.
                title: String(localized: "action.cloudNewTerminal", defaultValue: "New Terminal Workspace on Machine", bundle: .module),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "apple.terminal", surfaces: [.contextMenu],
                arguments: [CatalogArgument.cloudWorkspaceString], targets: [.machine], cliName: "cloud new-terminal-on-machine"
            ),
            ActionDescriptor(
                id: "cloudOpenMachine",
                title: String(localized: "action.cloudOpenMachine", defaultValue: "Open Machine", bundle: .module),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "server.rack", surfaces: [.contextMenu],
                targets: [.machine], cliName: "cloud open-machine"
            ),
            ActionDescriptor(
                id: "cloudRenameMachine",
                title: String(localized: "action.cloudRenameMachine", defaultValue: "Rename Machine…", bundle: .module),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "pencil", surfaces: [.contextMenu],
                arguments: [CatalogArgument.nameString.renamingTarget], targets: [.machine], cliName: "cloud rename-machine"
            ),
            ActionDescriptor(
                id: "cloudKillMachine",
                title: String(localized: "action.cloudKillMachine", defaultValue: "Kill Machine", bundle: .module),
                keywords: ["vm", "cloud tree", "delete"], category: .cloud, symbol: "xmark.octagon",
                surfaces: [.contextMenu], targets: [.machine], cliName: "cloud kill-machine",
                destructive: true
            ),
            ActionDescriptor(
                id: "cloudPauseMachine",
                title: String(localized: "action.cloudPauseMachine", defaultValue: "Pause Machine", bundle: .module),
                keywords: ["vm", "cloud tree", "pause", "sleep"], category: .cloud, symbol: "pause.circle",
                surfaces: [.palette, .contextMenu], requires: [.cloudWorkspace], targets: [.machine],
                cliName: "cloud pause-machine"
            ),
            ActionDescriptor(
                id: "cloudResumeMachine",
                title: String(localized: "action.cloudResumeMachine", defaultValue: "Resume Machine", bundle: .module),
                keywords: ["vm", "cloud tree", "resume", "wake", "start"], category: .cloud, symbol: "play.circle",
                surfaces: [.palette, .contextMenu], requires: [.cloudWorkspace], targets: [.machine],
                cliName: "cloud resume-machine"
            ),
            ActionDescriptor(
                id: "cloudCopyLink",
                title: String(localized: "action.cloudCopyLink", defaultValue: "Copy Machine Link", bundle: .module),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "link", surfaces: [.contextMenu],
                arguments: [CatalogArgument.portInt], targets: [.machine], cliName: "cloud copy-machine-link"
            ),
            ActionDescriptor(
                id: "cloudCopyPort",
                title: String(localized: "action.cloudCopyPort", defaultValue: "Copy Machine Port", bundle: .module),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "number", surfaces: [.contextMenu],
                arguments: [CatalogArgument.portInt], targets: [.machine], cliName: "cloud copy-machine-port"
            ),
            ActionDescriptor(
                id: "cloudCopyMachineID",
                title: String(localized: "action.cloudCopyMachineID", defaultValue: "Copy Machine ID", bundle: .module),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "doc.on.doc", surfaces: [.contextMenu],
                targets: [.machine], cliName: "cloud copy-machine-id"
            ),
            ActionDescriptor(
                id: "cloudResizeMachine",
                title: String(localized: "action.cloudResizeMachine", defaultValue: "Resize Machine…", bundle: .module),
                keywords: ["vm", "cloud tree", "cpu", "memory"], category: .cloud,
                symbol: "arrow.up.left.and.arrow.down.right", surfaces: [.contextMenu],
                arguments: [CatalogArgument.sizeChoice], targets: [.machine], cliName: "cloud resize-machine"
            ),
            ActionDescriptor(
                id: "cloudSetIdlePause",
                title: String(localized: "action.cloudSetIdlePause", defaultValue: "Pause When Idle…", bundle: .module),
                keywords: ["vm", "cloud tree", "idle", "auto-pause", "pause", "sleep", "timeout"], category: .cloud,
                symbol: "moon.zzz", surfaces: [.contextMenu],
                arguments: [CatalogArgument.idlePauseChoice], targets: [.machine], cliName: "cloud set-idle-pause"
            ),
            ActionDescriptor(
                id: "palette.cloud.deleteSnapshot",
                title: String(localized: "action.palette.cloud.deleteSnapshot", defaultValue: "Delete Cloud Snapshot…", bundle: .module),
                keywords: ["vm", "snapshot", "delete", "remove"], category: .cloud, symbol: "trash",
                surfaces: [.palette], requires: [.cloudWorkspace], arguments: [CatalogArgument.snapshotString, CatalogArgument.confirmBool],
                targets: [.machine], cliName: "cloud delete-snapshot", destructive: true
            ),
            ActionDescriptor(
                id: "cloudDiagnostics",
                title: String(localized: "action.cloudDiagnostics", defaultValue: "Cloud Diagnostics", bundle: .module),
                keywords: ["vm", "debug"], category: .cloud, symbol: "stethoscope", surfaces: [.menu],
                cliName: "cloud diagnostics", mainMenu: .help
            ),
            ActionDescriptor(
                id: "openTeamPicker",
                title: String(localized: "action.openTeamPicker", defaultValue: "Switch Active Team…", bundle: .module),
                keywords: ["team", "active", "account", "switch"],
                defaultShortcut: Shortcut("t", modifiers: [.option, .shift, .command]), category: .cloud,
                symbol: "person.2", surfaces: [.palette, .keyboard], arguments: [CatalogArgument.cloudTeam], cliName: "cloud team-picker"
            ),
            ActionDescriptor(
                id: "palette.auth.signIn",
                title: String(localized: "action.palette.auth.signIn", defaultValue: "Sign In", bundle: .module),
                keywords: ["account", "login"], category: .cloud, symbol: "person.crop.circle.badge.checkmark",
                surfaces: [.palette], requires: [.signedOut], cliName: "cloud sign-in"
            ),
            ActionDescriptor(
                id: "palette.auth.signOut",
                title: String(localized: "action.palette.auth.signOut", defaultValue: "Sign Out", bundle: .module),
                keywords: ["account", "logout"], category: .cloud, symbol: "person.crop.circle.badge.xmark",
                surfaces: [.palette], requires: [.signedIn], cliName: "cloud sign-out"
            ),
            ActionDescriptor(
                id: "palette.mobileConnect",
                title: String(localized: "action.palette.mobileConnect", defaultValue: "Open Mobile Pairing", bundle: .module),
                keywords: ["ios", "iphone", "phone", "mobile", "pair", "qr"], category: .cloud, symbol: "iphone.radiowaves.left.and.right",
                surfaces: [.palette, .menu], cliName: "cloud open-mobile-pairing", mainMenu: .window
            ),
        ]
        let waitsForResult: Set<ActionID> = [
            "cloudFilesList", "cloudFileRead", "cloudFileWrite", "cloudFileMkdir",
            "cloudFileRemove", "cloudFileStat", "cloudPrepareSCP",
            "cloudTunnelAttach", "cloudTunnelDetach", "cloudTunnelRotateKey", "cloudNetworkList",
            "cloudFirewallList", "cloudFirewallGet", "cloudFirewallCreate", "cloudFirewallDelete",
            "cloudDomainList", "cloudPublicationList", "cloudListMachines",
            // A CLI or agent run answers with the result: the machine's facts, the command's
            // output, the new machine's or workspace's id (CloudHandlers+Results.swift).
            "palette.cloud.status", "palette.cloud.ports", "palette.cloud.tools", "palette.cloud.handoff",
            "palette.cloud.snapshot", "palette.cloud.promoteTemplate", "cloudExec", "newCloudMachine", "cloudNewTerminal",
            // The new terminal tab's ids (`surface_id`), so a script can type into it next.
            "cloudSSH",
            "cloudSetupGitHub",
            // Each answers its machine's id (and the workspace's) once the server is done, so a CLI
            // caller hears a failure instead of OK, and can name the result in the next command.
            "palette.cloud.fork", "palette.cloud.restore", "newCloudWorkspace", "cloudRenameMachine", "cloudKillMachine",
            "cloudResizeMachine",
        ]
        for index in actions.indices where waitsForResult.contains(actions[index].id) {
            actions[index].waitsForResult = true
        }
        // What each one does and returns, for `action describe` and the MCP tools (CloudActionDescriptions).
        for index in actions.indices {
            actions[index].description = actions[index].description ?? CloudActionDescriptions.text[actions[index].id]
        }
        return actions
    }
}
