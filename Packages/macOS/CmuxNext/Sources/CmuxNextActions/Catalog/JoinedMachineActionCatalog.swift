// A machine joined through the hub (a pair code or a one-line token): what its "…" button in the
// right sidebar's Machines section offers. The App binds them (`MachineSectionHostView`), so the
// button's menu runs them through the registry like every other menu row. Titles live in
// RemoteActions.xcstrings. The CLI has its own verbs for them (`cmux machine doctor|rotate|revoke`,
// also `cmux device rotate|revoke`), which talk to the platform directly; these open the app's own
// checklist and confirmation. Rotate and Revoke are palette rows too, which pick the joined machine.

nonisolated enum JoinedMachineActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let machine: [ActionTargetKind] = [.machine]
        // The menu row's machine is its target; the palette lists the joined machines for it
        // (`PaletteSourcesBridge.joinedMachineTargets`), not the machines the app connects to.
        let joinedMachine = ActionArgument(name: "machine", title: t("argument.machine.joined", "Joined Machine"),
                                           kind: .target(.machine)).suppliedByTarget
        return [
            ActionDescriptor(
                id: "machine.joined.check", title: t("action.machine.joined.check", "Check Joined Machine"),
                keywords: ["machine", "joined", "join", "doctor", "health", "check", "mesh", "heartbeat"],
                category: .remote, symbol: "stethoscope", surfaces: [.contextMenu], targets: machine,
                surfacePlan: plan(.connection, 0, label: t("menu.machine.joined.check", "Check"))
            ),
            ActionDescriptor(
                id: "machine.joined.rotate", title: t("action.machine.joined.rotate", "Rotate Joined Machine's Credential"),
                keywords: ["machine", "joined", "join", "credential", "rotate", "key", "token", "secret"],
                category: .remote, symbol: "key", surfaces: [.palette, .contextMenu], arguments: [joinedMachine], targets: machine,
                surfacePlan: plan(.connection, 1, label: t("menu.machine.joined.rotate", "Rotate Credential"), palette: .offered)
            ),
            ActionDescriptor(
                id: "machine.joined.revoke", title: t("action.machine.joined.revoke", "Revoke Joined Machine…"),
                keywords: ["machine", "joined", "join", "revoke", "remove", "disconnect", "access", "team"],
                category: .remote, symbol: "xmark.circle", surfaces: [.palette, .contextMenu], arguments: [joinedMachine], targets: machine,
                surfacePlan: plan(.close, 0, label: t("menu.machine.joined.revoke", "Revoke…"), palette: .offered)
            ),
        ]
    }

    /// A row of the joined machine's menu; `label` is its shorter title there. Check stays the row's
    /// alone: it records its result on the row it opened from.
    private static func plan(_ group: MenuGroup, _ rank: Int, label: String,
                             palette: SurfaceDecision = .exempt(.guiOnly)) -> ActionSurfacePlan {
        ActionSurfacePlan(palette: palette, cli: .exempt(.guiOnly),
                          contextMenus: [ContextMenuPlacement(.joinedMachine, group, rank, label: label)])
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "RemoteActions", bundle: .module)
    }
}
