// A machine joined with a one-line token (Labs `labs.machineJoin`): what its "…" button in the
// right sidebar's Machines section offers. The App binds them (`MachineSectionHostView`), so the
// button's menu runs them through the registry like every other menu row. Titles live in
// RemoteActions.xcstrings. The CLI has its own verbs for them (`cmux machine doctor|rotate|revoke`),
// which talk to the platform directly; these open the app's own checklist and confirmation.

nonisolated enum JoinedMachineActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let machine: [ActionTargetKind] = [.machine]
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
                category: .remote, symbol: "key", surfaces: [.contextMenu], targets: machine,
                surfacePlan: plan(.connection, 1, label: t("menu.machine.joined.rotate", "Rotate Credential"))
            ),
            ActionDescriptor(
                id: "machine.joined.revoke", title: t("action.machine.joined.revoke", "Revoke Joined Machine…"),
                keywords: ["machine", "joined", "join", "revoke", "remove", "disconnect", "access", "team"],
                category: .remote, symbol: "xmark.circle", surfaces: [.contextMenu], targets: machine,
                surfacePlan: plan(.close, 0, label: t("menu.machine.joined.revoke", "Revoke…"))
            ),
        ]
    }

    /// A row of the joined machine's menu; `label` is its shorter title there. The palette's machine
    /// picker lists the machines the app connects to, not joined ones, so only the row's menu offers them.
    private static func plan(_ group: MenuGroup, _ rank: Int, label: String) -> ActionSurfacePlan {
        ActionSurfacePlan(palette: .exempt(.guiOnly), cli: .exempt(.guiOnly),
                          contextMenus: [ContextMenuPlacement(.joinedMachine, group, rank, label: label)])
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "RemoteActions", bundle: .module)
    }
}
