// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum CloudActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var actions: [ActionDescriptor] = [
            ActionDescriptor(
                id: "newCloudWorkspace",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.newCloudWorkspace") + "\u{E002}" + String(localized: "action.newCloudWorkspace", defaultValue: "New Cloud Workspace", bundle: .module)),
                keywords: ["vm", "remote", "create"], defaultShortcut: Shortcut("y", modifiers: [.command, .shift]),
                category: .cloud, symbol: "cloud", surfaces: [.keyboard, .menu, .contextMenu], targets: [.machine],
                cliName: "cloud new-workspace", mainMenu: .file
            ),
            ActionDescriptor(
                id: "newCloudMachine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.newCloudMachine") + "\u{E002}" + String(localized: "action.newCloudMachine", defaultValue: "New Cloud Machine…", bundle: .module)),
                keywords: ["vm", "remote", "create"],
                category: .cloud, symbol: "server.rack", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                // All optional: `cmux cloud new-machine --persistent --size medium --name lane-vm-1
                // --bootstrap lane --bootstrap-script FILE` makes a lane host in one call.
                arguments: [CatalogArgument.nameString.optional, CatalogArgument.newMachineSizeString, CatalogArgument.persistentBool,
                            CatalogArgument.bootstrapString, CatalogArgument.bootstrapScriptString, CatalogArgument.machineConfigString,
                            CatalogArgument.repoString],
                cliName: "cloud new-machine", mainMenu: .file
            ),
            ActionDescriptor(
                id: "palette.cloud.fork",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.fork") + "\u{E002}" + String(localized: "action.palette.cloud.fork", defaultValue: "Fork Cloud Machine", bundle: .module)),
                keywords: ["vm", "clone"], category: .cloud, symbol: "arrow.triangle.branch", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud fork-machine"
            ),
            ActionDescriptor(
                id: "palette.cloud.snapshot",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.snapshot") + "\u{E002}" + String(localized: "action.palette.cloud.snapshot", defaultValue: "Snapshot Cloud Machine", bundle: .module)),
                keywords: ["vm", "backup"], category: .cloud, symbol: "camera.aperture", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud snapshot-machine"
            ),
            ActionDescriptor(
                id: "palette.cloud.restore",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.restore") + "\u{E002}" + String(localized: "action.palette.cloud.restore", defaultValue: "Restore Cloud Machine…", bundle: .module)),
                keywords: ["vm", "snapshot"], category: .cloud, symbol: "clock.arrow.2.circlepath",
                surfaces: [.palette], requires: [.cloudWorkspace], arguments: [CatalogArgument.snapshotString],
                targets: [.machine], cliName: "cloud restore-machine"
            ),
            ActionDescriptor(
                id: "palette.cloud.promoteTemplate",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.promoteTemplate") + "\u{E002}" + String(localized: "action.palette.cloud.promoteTemplate", defaultValue: "Promote Machine to Template", bundle: .module)),
                keywords: ["vm", "template"], category: .cloud, symbol: "star.square", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud promote-machine-to-template"
            ),
            ActionDescriptor(
                id: "palette.cloud.status",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.status") + "\u{E002}" + String(localized: "action.palette.cloud.status", defaultValue: "Cloud Machine Status", bundle: .module)),
                keywords: ["vm", "health"], category: .cloud, symbol: "waveform.path.ecg", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud machine-status"
            ),
            ActionDescriptor(
                id: "palette.cloud.ports",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.ports") + "\u{E002}" + String(localized: "action.palette.cloud.ports", defaultValue: "Cloud Machine Ports", bundle: .module)),
                keywords: ["vm", "forward"], category: .cloud, symbol: "network", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud machine-ports"
            ),
            ActionDescriptor(
                id: "palette.cloud.tools",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.tools") + "\u{E002}" + String(localized: "action.palette.cloud.tools", defaultValue: "Cloud Machine Tools", bundle: .module)),
                keywords: ["vm"], category: .cloud, symbol: "wrench.and.screwdriver", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud machine-tools"
            ),
            ActionDescriptor(
                id: "palette.cloud.handoff",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.handoff") + "\u{E002}" + String(localized: "action.palette.cloud.handoff", defaultValue: "Hand Off Cloud Machine", bundle: .module)),
                keywords: ["vm", "share"], category: .cloud, symbol: "hand.raised", surfaces: [.palette],
                requires: [.cloudWorkspace], targets: [.machine], cliName: "cloud hand-off-machine"
            ),
            // Move to Cloud (cmuxterm-hq#1874 slice 3): the palette, the tab and chat
            // right-click menus and `cmux cloud move` run this one action on a chat tab.
            ActionDescriptor(
                id: "cloudMove",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudMove") + "\u{E002}" + String(localized: "action.cloudMove", defaultValue: "Move to Cloud", bundle: .module)),
                keywords: ["vm", "cloud", "move", "chat", "agent", "remote", "sync"], category: .cloud,
                symbol: "icloud.and.arrow.up", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.optionalPathString, CatalogArgument.optionalMachine], targets: [.tab],
                cliName: "cloud move"
            ),
            // Bring Back Local (cmuxterm-hq#1874 slice 4): the reverse, on a Cloud chat tab that
            // a move from this Mac put there.
            ActionDescriptor(
                id: "cloudBringBack",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudBringBack") + "\u{E002}" + String(localized: "action.cloudBringBack", defaultValue: "Bring Back Local", bundle: .module)),
                keywords: ["vm", "cloud", "move", "back", "local", "chat", "agent", "sync"], category: .cloud,
                symbol: "icloud.and.arrow.down", surfaces: [.palette, .contextMenu], targets: [.tab],
                cliName: "cloud bring-back"
            ),
            ActionDescriptor(
                id: "cloudSSH",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudSSH") + "\u{E002}" + String(localized: "action.cloudSSH", defaultValue: "Open Cloud SSH Terminal", bundle: .module)),
                keywords: ["vm", "cloud", "ssh", "terminal"], category: .cloud, symbol: "terminal",
                surfaces: [.palette, .contextMenu], targets: [.machine],
                cliName: "cloud ssh", startsTerminal: true
            ),
            ActionDescriptor(
                id: "cloudExec",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudExec") + "\u{E002}" + String(localized: "action.cloudExec", defaultValue: "Run Command on Cloud Machine…", bundle: .module)),
                keywords: ["vm", "cloud", "exec", "command"], category: .cloud, symbol: "terminal.fill",
                surfaces: [.palette], requires: [.cloudWorkspace], arguments: [CatalogArgument.commandString], targets: [.machine],
                cliName: "cloud exec", startsTerminal: true
            ),
            // One click on a machine: this Mac's git identity, and a gh sign-in the person approves
            // in their browser (device flow); no token leaves the Mac (CloudGitHubSetup).
            ActionDescriptor(
                id: "cloudSetupGitHub",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudSetupGitHub") + "\u{E002}" + String(localized: "action.cloudSetupGitHub", defaultValue: "Set Up GitHub on This Machine", bundle: .module)),
                keywords: ["vm", "cloud", "github", "gh", "git", "login", "sign in", "identity"], category: .cloud,
                symbol: "person.badge.key", surfaces: [.palette, .contextMenu], targets: [.machine],
                cliName: "cloud setup-github"
            ),
            ActionDescriptor(
                id: "cloudFilesList",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudFilesList") + "\u{E002}" + String(localized: "action.cloudFilesList", defaultValue: "List Cloud Files…", bundle: .module)),
                keywords: ["vm", "cloud", "files", "directory", "ls"], category: .cloud, symbol: "folder",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], targets: [.machine],
                cliName: "cloud files-list"
            ),
            ActionDescriptor(
                id: "cloudFileRead",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudFileRead") + "\u{E002}" + String(localized: "action.cloudFileRead", defaultValue: "Read Cloud File…", bundle: .module)),
                keywords: ["vm", "cloud", "files", "read"], category: .cloud, symbol: "doc.text",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], targets: [.machine],
                cliName: "cloud file-read"
            ),
            ActionDescriptor(
                id: "cloudFileWrite",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudFileWrite") + "\u{E002}" + String(localized: "action.cloudFileWrite", defaultValue: "Write Cloud File…", bundle: .module)),
                keywords: ["vm", "cloud", "files", "write"], category: .cloud, symbol: "square.and.pencil",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString, CatalogArgument.contentsString], targets: [.machine],
                cliName: "cloud file-write"
            ),
            ActionDescriptor(
                id: "cloudFileMkdir",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudFileMkdir") + "\u{E002}" + String(localized: "action.cloudFileMkdir", defaultValue: "Create Cloud Directory…", bundle: .module)),
                keywords: ["vm", "cloud", "files", "mkdir"], category: .cloud, symbol: "folder.badge.plus",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], targets: [.machine],
                cliName: "cloud file-mkdir"
            ),
            ActionDescriptor(
                id: "cloudFileRemove",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudFileRemove") + "\u{E002}" + String(localized: "action.cloudFileRemove", defaultValue: "Remove Cloud File…", bundle: .module)),
                keywords: ["vm", "cloud", "files", "rm"], category: .cloud, symbol: "trash",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString, CatalogArgument.confirmBool], targets: [.machine],
                cliName: "cloud file-remove", destructive: true
            ),
            ActionDescriptor(
                id: "cloudFileStat",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudFileStat") + "\u{E002}" + String(localized: "action.cloudFileStat", defaultValue: "Cloud File Details…", bundle: .module)),
                keywords: ["vm", "cloud", "files", "stat"], category: .cloud, symbol: "info.circle",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], targets: [.machine],
                cliName: "cloud file-stat"
            ),
            ActionDescriptor(
                id: "cloudPrepareSCP",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudPrepareSCP") + "\u{E002}" + String(localized: "action.cloudPrepareSCP", defaultValue: "Prepare Cloud File Transfer…", bundle: .module)),
                keywords: ["vm", "cloud", "files", "scp", "ssh"], category: .cloud, symbol: "arrow.up.arrow.down",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.publicKeyString], targets: [.machine],
                cliName: "cloud prepare-scp"
            ),
            ActionDescriptor(id: "cloudTunnelAttach", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudTunnelAttach") + "\u{E002}" + String(localized: "action.cloudTunnelAttach", defaultValue: "Attach Cloud Tunnel Network", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "tunnel", "network"], category: .cloud, symbol: "link", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], cliName: "cloud tunnel-attach"),
            ActionDescriptor(id: "cloudTunnelDetach", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudTunnelDetach") + "\u{E002}" + String(localized: "action.cloudTunnelDetach", defaultValue: "Detach Cloud Tunnel Network", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "tunnel", "network"], category: .cloud, symbol: "scissors", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], cliName: "cloud tunnel-detach"),
            ActionDescriptor(id: "cloudTunnelRotateKey", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudTunnelRotateKey") + "\u{E002}" + String(localized: "action.cloudTunnelRotateKey", defaultValue: "Rotate Cloud Tunnel Key", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "tunnel", "key"], category: .cloud, symbol: "key", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.publicKeyString], cliName: "cloud tunnel-rotate-key"),
            ActionDescriptor(id: "cloudNetworkList", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudNetworkList") + "\u{E002}" + String(localized: "action.cloudNetworkList", defaultValue: "List Cloud Networks", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "network", "vpc"], category: .cloud, symbol: "network", surfaces: [.palette, .contextMenu], cliName: "cloud network-list"),
            ActionDescriptor(id: "cloudFirewallList", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudFirewallList") + "\u{E002}" + String(localized: "action.cloudFirewallList", defaultValue: "List Cloud Firewall Rules", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "firewall", "network"], category: .cloud, symbol: "shield", surfaces: [.palette, .contextMenu], cliName: "cloud firewall-list"),
            ActionDescriptor(id: "cloudFirewallGet", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudFirewallGet") + "\u{E002}" + String(localized: "action.cloudFirewallGet", defaultValue: "Get Cloud Firewall Rule", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "firewall", "network"], category: .cloud, symbol: "shield.checkered", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], cliName: "cloud firewall-get"),
            ActionDescriptor(id: "cloudFirewallCreate", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudFirewallCreate") + "\u{E002}" + String(localized: "action.cloudFirewallCreate", defaultValue: "Create Cloud Firewall Rule", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "firewall", "network"], category: .cloud, symbol: "shield.lefthalf.filled", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString], cliName: "cloud firewall-create"),
            ActionDescriptor(id: "cloudFirewallDelete", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudFirewallDelete") + "\u{E002}" + String(localized: "action.cloudFirewallDelete", defaultValue: "Delete Cloud Firewall Rule", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "firewall", "network"], category: .cloud, symbol: "shield.slash", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.pathString, CatalogArgument.confirmBool], cliName: "cloud firewall-delete", destructive: true),
            ActionDescriptor(id: "cloudDomainList", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudDomainList") + "\u{E002}" + String(localized: "action.cloudDomainList", defaultValue: "List Cloud Domains", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "domain", "dns", "verify"], category: .cloud, symbol: "globe", surfaces: [.palette], cliName: "cloud domain-list"),
            ActionDescriptor(id: "cloudPublicationList", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudPublicationList") + "\u{E002}" + String(localized: "action.cloudPublicationList", defaultValue: "List Cloud Publications", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "domain", "publication", "tls"], category: .cloud, symbol: "globe.americas", surfaces: [.palette], cliName: "cloud publication-list"),
            // A machine port as an API behind a key (#25594): publish it protected, mint a key, answer both.
            ActionDescriptor(
                id: "cloudProvisionAPI",
                title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudProvisionAPI") + "\u{E002}" + String(localized: "action.cloudProvisionAPI", defaultValue: "Provision API on Machine…", table: "ActionCatalog", bundle: .module)),
                keywords: ["cloud", "api", "endpoint", "publish", "port", "key", "url"], category: .cloud, symbol: "square.and.arrow.up",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.portInt, CatalogArgument.apiKeyNameString], targets: [.machine],
                cliName: "cloud provision-api"
            ),
            ActionDescriptor(id: "cloudAPIKeyList", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudAPIKeyList") + "\u{E002}" + String(localized: "action.cloudAPIKeyList", defaultValue: "List Cloud API Keys", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "api", "key", "publication"], category: .cloud, symbol: "key", surfaces: [.palette], arguments: [CatalogArgument.pathString], cliName: "cloud api-key-list"),
            ActionDescriptor(id: "cloudAPIKeyRevoke", title: ("\u{E000}ActionCatalog\u{E001}" + String(describing: "action.cloudAPIKeyRevoke") + "\u{E002}" + String(localized: "action.cloudAPIKeyRevoke", defaultValue: "Revoke Cloud API Key", table: "ActionCatalog", bundle: .module)), keywords: ["cloud", "api", "key", "revoke", "publication"], category: .cloud, symbol: "key.slash", surfaces: [.palette], arguments: [CatalogArgument.pathString, CatalogArgument.apiKeyString, CatalogArgument.confirmBool], cliName: "cloud api-key-revoke", destructive: true),
            // Read only: a CLI or agent run answers the app's own machine list (the sidebar's
            // Cloud machines) as `result`; a person's run shows the Cloud sidebar.
            ActionDescriptor(
                id: "cloudListMachines",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudListMachines") + "\u{E002}" + String(localized: "action.cloudListMachines", defaultValue: "List Cloud Machines", bundle: .module)),
                keywords: ["vm", "cloud", "machines", "list", "inventory"], category: .cloud, symbol: "list.bullet.rectangle",
                surfaces: [.palette], cliName: "cloud list-machines"
            ),
            ActionDescriptor(
                id: "cloudNewTerminal",
                // It makes a workspace (with a terminal), so its title says so; `--workspace <id>` adds
                // a terminal tab to that workspace of the machine instead. The CLI name stays for scripts.
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudNewTerminal") + "\u{E002}" + String(localized: "action.cloudNewTerminal", defaultValue: "New Terminal Workspace on Machine", bundle: .module)),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "apple.terminal", surfaces: [.contextMenu],
                arguments: [CatalogArgument.cloudWorkspaceString], targets: [.machine], cliName: "cloud new-terminal-on-machine"
            ),
            ActionDescriptor(
                id: "cloudOpenMachine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudOpenMachine") + "\u{E002}" + String(localized: "action.cloudOpenMachine", defaultValue: "Open Machine", bundle: .module)),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "server.rack", surfaces: [.contextMenu],
                targets: [.machine], cliName: "cloud open-machine"
            ),
            ActionDescriptor(
                id: "cloudOpenDesktop",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudOpenDesktop") + "\u{E002}" + String(localized: "action.cloudOpenDesktop", defaultValue: "Open Desktop", bundle: .module)),
                keywords: ["vm", "cloud tree", "desktop", "display", "screen", "vnc", "computer use"], category: .cloud,
                symbol: "display", surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.desktopViewerChoice],
                targets: [.machine], cliName: "cloud open-desktop"
            ),
            ActionDescriptor(
                id: "cloudRenameMachine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudRenameMachine") + "\u{E002}" + String(localized: "action.cloudRenameMachine", defaultValue: "Rename Machine…", bundle: .module)),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "pencil", surfaces: [.contextMenu],
                arguments: [CatalogArgument.nameString.renamingTarget], targets: [.machine], cliName: "cloud rename-machine"
            ),
            ActionDescriptor(
                id: "cloudKillMachine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudKillMachine") + "\u{E002}" + String(localized: "action.cloudKillMachine", defaultValue: "Kill Machine", bundle: .module)),
                keywords: ["vm", "cloud tree", "delete"], category: .cloud, symbol: "xmark.octagon",
                surfaces: [.contextMenu], targets: [.machine], cliName: "cloud kill-machine",
                destructive: true
            ),
            ActionDescriptor(
                id: "cloudPauseMachine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudPauseMachine") + "\u{E002}" + String(localized: "action.cloudPauseMachine", defaultValue: "Pause Machine", bundle: .module)),
                keywords: ["vm", "cloud tree", "pause", "sleep"], category: .cloud, symbol: "pause.circle",
                surfaces: [.palette, .contextMenu], requires: [.cloudWorkspace], targets: [.machine],
                cliName: "cloud pause-machine"
            ),
            ActionDescriptor(
                id: "cloudResumeMachine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudResumeMachine") + "\u{E002}" + String(localized: "action.cloudResumeMachine", defaultValue: "Resume Machine", bundle: .module)),
                keywords: ["vm", "cloud tree", "resume", "wake", "start"], category: .cloud, symbol: "play.circle",
                surfaces: [.palette, .contextMenu], requires: [.cloudWorkspace], targets: [.machine],
                cliName: "cloud resume-machine"
            ),
            ActionDescriptor(
                id: "cloudCopyLink",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudCopyLink") + "\u{E002}" + String(localized: "action.cloudCopyLink", defaultValue: "Copy Machine Link", bundle: .module)),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "link", surfaces: [.contextMenu],
                arguments: [CatalogArgument.portInt], targets: [.machine], cliName: "cloud copy-machine-link"
            ),
            ActionDescriptor(
                id: "cloudCopyPort",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudCopyPort") + "\u{E002}" + String(localized: "action.cloudCopyPort", defaultValue: "Copy Machine Port", bundle: .module)),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "number", surfaces: [.contextMenu],
                arguments: [CatalogArgument.portInt], targets: [.machine], cliName: "cloud copy-machine-port"
            ),
            ActionDescriptor(
                id: "cloudCopyMachineID",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudCopyMachineID") + "\u{E002}" + String(localized: "action.cloudCopyMachineID", defaultValue: "Copy Machine ID", bundle: .module)),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "doc.on.doc", surfaces: [.contextMenu],
                targets: [.machine], cliName: "cloud copy-machine-id"
            ),
            ActionDescriptor(
                id: "cloudResizeMachine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudResizeMachine") + "\u{E002}" + String(localized: "action.cloudResizeMachine", defaultValue: "Resize Machine…", bundle: .module)),
                keywords: ["vm", "cloud tree", "cpu", "memory", "disk", "storage"], category: .cloud,
                symbol: "arrow.up.left.and.arrow.down.right", surfaces: [.contextMenu],
                arguments: [CatalogArgument.sizeChoice.optional, CatalogArgument.diskGiBInt], targets: [.machine], cliName: "cloud resize-machine"
            ),
            // `cmux cloud enroll-machine --target machine:<id> --name lane-vm-1`: ssh from this Mac
            // through the app's tunnel, and an acpmux peer (CloudMachineEnrollment).
            ActionDescriptor(
                id: "cloudEnrollMachine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudEnrollMachine") + "\u{E002}" + String(localized: "action.cloudEnrollMachine", defaultValue: "Enroll Machine as Agent Host", bundle: .module)),
                keywords: ["vm", "cloud", "ssh", "acpmux", "agent", "host", "peer", "lane", "enroll"], category: .cloud,
                symbol: "key.horizontal", surfaces: [.palette, .contextMenu], requires: [.cloudWorkspace],
                arguments: [CatalogArgument.nameString.optional, CatalogArgument.sshKeyString], targets: [.machine],
                cliName: "cloud enroll-machine"
            ),
            // `cmux cloud apply-machine-config --target machine:<id> [--machine-config FILE]`: env, secret
            // names and setup from `.cmux/machine.toml` (CloudMachineConfig).
            ActionDescriptor(
                id: "cloudApplyMachineConfig",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudApplyMachineConfig") + "\u{E002}" + String(localized: "action.cloudApplyMachineConfig", defaultValue: "Apply Machine Config", bundle: .module)),
                keywords: ["vm", "cloud", "env", "environment", "setup", "secrets", "config", "toml"], category: .cloud,
                symbol: "gearshape.2", surfaces: [.palette, .contextMenu], requires: [.cloudWorkspace],
                arguments: [CatalogArgument.machineConfigString], targets: [.machine], cliName: "cloud apply-machine-config"
            ),
            // `cmux cloud deliver-secrets --target machine:<id>`: values of the declared secret names, over the
            // machine's daemon link (CloudMachineSecrets), or of `--names` to an own machine over ssh
            // (SSHMachineSecrets); `cmux cloud secret set` stores them (Rust CLI).
            ActionDescriptor(
                id: "cloudDeliverSecrets",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudDeliverSecrets") + "\u{E002}" + String(localized: "action.cloudDeliverSecrets", defaultValue: "Deliver Secrets to Machine", bundle: .module)),
                keywords: ["vm", "cloud", "secrets", "env", "keychain", "config"], category: .cloud,
                symbol: "lock.rectangle.stack", surfaces: [.palette, .contextMenu], requires: [.cloudWorkspace],
                arguments: [CatalogArgument.secretRepoString, CatalogArgument.secretNamesString], targets: [.machine], cliName: "cloud deliver-secrets"
            ),
            ActionDescriptor(
                id: "cloudSetIdlePause",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudSetIdlePause") + "\u{E002}" + String(localized: "action.cloudSetIdlePause", defaultValue: "Pause When Idle…", bundle: .module)),
                keywords: ["vm", "cloud tree", "idle", "auto-pause", "pause", "sleep", "timeout"], category: .cloud,
                symbol: "moon.zzz", surfaces: [.contextMenu],
                arguments: [CatalogArgument.idlePauseChoice], targets: [.machine], cliName: "cloud set-idle-pause"
            ),
            ActionDescriptor(
                id: "cloudSetNetworkAccess",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudSetNetworkAccess") + "\u{E002}" + String(localized: "action.cloudSetNetworkAccess", defaultValue: "Internet Access…", bundle: .module)),
                keywords: ["vm", "network", "internet", "egress", "allowlist", "firewall", "offline", "sandbox"], category: .cloud,
                symbol: "globe", surfaces: [.contextMenu],
                arguments: [CatalogArgument.networkAccessChoice], targets: [.machine], cliName: "cloud set-network-access"
            ),
            ActionDescriptor(
                id: "palette.cloud.deleteSnapshot",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.cloud.deleteSnapshot") + "\u{E002}" + String(localized: "action.palette.cloud.deleteSnapshot", defaultValue: "Delete Cloud Snapshot…", bundle: .module)),
                keywords: ["vm", "snapshot", "delete", "remove"], category: .cloud, symbol: "trash",
                surfaces: [.palette], requires: [.cloudWorkspace], arguments: [CatalogArgument.snapshotString, CatalogArgument.confirmBool],
                targets: [.machine], cliName: "cloud delete-snapshot", destructive: true
            ),
            ActionDescriptor(
                id: "cloudDiagnostics",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.cloudDiagnostics") + "\u{E002}" + String(localized: "action.cloudDiagnostics", defaultValue: "Cloud Diagnostics", bundle: .module)),
                keywords: ["vm", "debug"], category: .cloud, symbol: "stethoscope", surfaces: [.menu],
                cliName: "cloud diagnostics", mainMenu: .help
            ),
            ActionDescriptor(
                id: "openTeamPicker",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.openTeamPicker") + "\u{E002}" + String(localized: "action.openTeamPicker", defaultValue: "Switch Active Team…", bundle: .module)),
                keywords: ["team", "active", "account", "switch"],
                defaultShortcut: Shortcut("t", modifiers: [.option, .shift, .command]), category: .cloud,
                symbol: "person.2", surfaces: [.palette, .keyboard], arguments: [CatalogArgument.cloudTeam], cliName: "cloud team-picker"
            ),
            ActionDescriptor(
                id: "palette.auth.signIn",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.auth.signIn") + "\u{E002}" + String(localized: "action.palette.auth.signIn", defaultValue: "Sign In", bundle: .module)),
                keywords: ["account", "login"], category: .cloud, symbol: "person.crop.circle.badge.checkmark",
                surfaces: [.palette], requires: [.signedOut], cliName: "cloud sign-in"
            ),
            ActionDescriptor(
                id: "palette.auth.signOut",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.auth.signOut") + "\u{E002}" + String(localized: "action.palette.auth.signOut", defaultValue: "Sign Out", bundle: .module)),
                keywords: ["account", "logout"], category: .cloud, symbol: "person.crop.circle.badge.xmark",
                surfaces: [.palette], requires: [.signedIn], cliName: "cloud sign-out"
            ),
            ActionDescriptor(
                id: "palette.mobileConnect",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.mobileConnect") + "\u{E002}" + String(localized: "action.palette.mobileConnect", defaultValue: "Open Mobile Pairing", bundle: .module)),
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
            "cloudProvisionAPI", "cloudAPIKeyList", "cloudAPIKeyRevoke",
            // A CLI or agent run answers with the result: the machine's facts, the command's
            // output, the new machine's or workspace's id (CloudHandlers+Results.swift).
            "palette.cloud.status", "palette.cloud.ports", "palette.cloud.tools", "palette.cloud.handoff",
            "palette.cloud.snapshot", "palette.cloud.promoteTemplate", "cloudExec", "newCloudMachine", "cloudNewTerminal",
            // The new terminal tab's ids (`surface_id`), so a script can type into it next.
            "cloudSSH",
            "cloudSetupGitHub", "cloudEnrollMachine",
            // Each answers its machine's id (and the workspace's) once the server is done, so a CLI
            // caller hears a failure instead of OK, and can name the result in the next command.
            "palette.cloud.fork", "palette.cloud.restore", "newCloudWorkspace", "cloudRenameMachine", "cloudKillMachine",
            "cloudResizeMachine", "cloudApplyMachineConfig", "cloudDeliverSecrets",
            // The stored policy's mode and whether the server applied it (a PUT can take a while).
            "cloudSetNetworkAccess",
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
