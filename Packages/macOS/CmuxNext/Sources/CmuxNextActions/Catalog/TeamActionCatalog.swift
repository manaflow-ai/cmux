// Invite to Team (`team.invite`): emails an invite to join a cmux team, for the CLI
// (`cmux team invite --email … [--team …] [--role member|admin] --reason "…"`), the MCP
// tool and agents. Every run waits for the person's Send Invite on a confirmation panel
// first: an accepted invite adds a member and can raise the team's bill.

nonisolated enum TeamActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var invite = ActionDescriptor(
            id: "team.invite",
            title: String(localized: "action.team.invite", defaultValue: "Invite to Team…", bundle: .module),
            description: String(localized: "action.team.invite.description",
                                defaultValue: "Email an invite to join a cmux team. You confirm each invite in cmux before it is sent.",
                                bundle: .module),
            keywords: ["team", "invite", "member", "seat", "email", "people", "add", "join", "organization"],
            category: .settings, symbol: "person.badge.plus",
            surfaces: [.palette],
            arguments: [
                ActionArgument(name: "email", title: String(localized: "argument.team.invite.email", defaultValue: "Email Addresses",
                                                            bundle: .module), kind: .string),
                ActionArgument(name: "team", title: String(localized: "argument.team.invite.team", defaultValue: "Team",
                                                           bundle: .module), kind: .string, isRequired: false),
                ActionArgument(name: "role", title: String(localized: "argument.team.invite.role", defaultValue: "Role",
                                                           bundle: .module), kind: .string, isRequired: false),
                ActionArgument(name: "reason", title: String(localized: "argument.team.invite.reason", defaultValue: "Reason",
                                                             bundle: .module), kind: .string, isRequired: false),
            ],
            cliName: "team invite",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
        )
        // The person answers the confirmation panel: the run waits for it.
        invite.waitsForPerson = true
        return [invite]
    }
}
