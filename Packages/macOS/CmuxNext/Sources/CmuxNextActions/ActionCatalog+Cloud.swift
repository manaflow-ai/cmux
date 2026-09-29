// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func cloudActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "newCloudWorkspace",
                title: String(localized: "action.newCloudWorkspace", defaultValue: "New Cloud Workspace", bundle: .module),
                keywords: ["vm", "remote", "create"], defaultShortcut: Shortcut("y", modifiers: [.command, .shift]),
                category: .cloud, symbol: "cloud.fill", surfaces: [.keyboard, .menu, .contextMenu],
                cliName: "cloud new-workspace", mainMenu: .file
            ),
            ActionDescriptor(
                id: "newCloudMachine",
                title: String(localized: "action.newCloudMachine", defaultValue: "New Cloud Machine…", bundle: .module),
                keywords: ["vm", "remote", "create"], defaultShortcut: Shortcut("y", modifiers: [.command]),
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
            ActionDescriptor(
                id: "cloudNewTerminal",
                title: String(localized: "action.cloudNewTerminal", defaultValue: "New Terminal on Machine", bundle: .module),
                keywords: ["vm", "cloud tree"], category: .cloud, symbol: "apple.terminal", surfaces: [.contextMenu],
                targets: [.machine], cliName: "cloud new-terminal-on-machine"
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
                arguments: [CatalogArgument.nameString], targets: [.machine], cliName: "cloud rename-machine"
            ),
            ActionDescriptor(
                id: "cloudKillMachine",
                title: String(localized: "action.cloudKillMachine", defaultValue: "Kill Machine", bundle: .module),
                keywords: ["vm", "cloud tree", "delete"], category: .cloud, symbol: "xmark.octagon",
                surfaces: [.contextMenu], targets: [.machine], cliName: "cloud kill-machine",
                destructive: true
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
                id: "cloudDiagnostics",
                title: String(localized: "action.cloudDiagnostics", defaultValue: "Cloud Diagnostics…", bundle: .module),
                keywords: ["vm", "debug"], category: .cloud, symbol: "stethoscope", surfaces: [.menu],
                cliName: "cloud diagnostics", mainMenu: .help
            ),
            ActionDescriptor(
                id: "openTeamPicker",
                title: String(localized: "action.openTeamPicker", defaultValue: "Team Picker", bundle: .module),
                keywords: ["team", "account", "switch"],
                defaultShortcut: Shortcut("t", modifiers: [.option, .shift, .command]), category: .cloud,
                symbol: "person.2", surfaces: [.palette, .keyboard], cliName: "cloud team-picker"
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
                keywords: ["ios", "phone", "pair"], category: .cloud, symbol: "iphone.radiowaves.left.and.right",
                surfaces: [.palette], cliName: "cloud open-mobile-pairing"
            ),
        ]
    }
}
