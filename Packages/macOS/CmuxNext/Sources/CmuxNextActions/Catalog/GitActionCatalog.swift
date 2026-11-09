// The session host's git worktree and checkpoint verbs in the palette (Leo, 2026-11-08: "Every
// conceivable possible aspect of the app"). Each runs the operation `cmux git worktree
// create|apply|remove` and `cmux git checkpoint create` send, in the folder of the focused tab
// (GitRepositoryHandlers), so the CLI keeps its own words: the session host owns the verb.
// Titles live in ActionCatalog.xcstrings.

nonisolated enum GitActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        // The repository is the focused tab's folder, which has no right-click menu of its own.
        let plan = ActionSurfacePlan(cli: .exempt(.ownerVerb), contextMenuExemption: .noTargetSurface)
        return [
            ActionDescriptor(
                id: "git.worktree.create", title: t("action.git.worktree.create", "New Git Worktree"),
                keywords: ["git", "worktree", "branch", "checkout", "new", "create", "isolate"],
                category: .tab, symbol: "arrow.triangle.branch",
                arguments: [
                    ActionArgument(name: "name", title: t("argument.git.worktree.name", "Worktree Name"), kind: .string, isRequired: false),
                    ActionArgument(name: "base", title: t("argument.git.worktree.base", "Base Revision"), kind: .string, isRequired: false),
                ],
                targets: [.tab],
                surfacePlan: plan
            ),
            ActionDescriptor(
                id: "git.worktree.apply", title: t("action.git.worktree.apply", "Apply Worktree to Main Checkout"),
                keywords: ["git", "worktree", "apply", "merge", "bring back", "main", "checkout"],
                category: .tab, symbol: "arrow.down.to.line",
                targets: [.tab],
                surfacePlan: plan
            ),
            // Refused with work found nowhere else unless `discard` (`cmux git worktree remove --discard`).
            // Destructive: it deletes the worktree's folder, and with `discard` its unsaved work, so
            // the palette asks first and a script must pass `confirm`.
            ActionDescriptor(
                id: "git.worktree.remove", title: t("action.git.worktree.remove", "Remove Git Worktree"),
                keywords: ["git", "worktree", "remove", "delete", "clean up", "branch"],
                category: .tab, symbol: "trash",
                arguments: [ActionArgument(name: "discard", title: t("argument.git.worktree.discard", "Discard Unsaved Work"), kind: .bool, isRequired: false)],
                targets: [.tab],
                destructive: true,
                surfacePlan: plan
            ),
            // A headless capture (`cmux git checkpoint create`); an agent chat's Create Checkpoint
            // (agentPane.createCheckpoint) opens its review checklist instead.
            ActionDescriptor(
                id: "git.checkpoint.create", title: t("action.git.checkpoint.create", "Create Git Checkpoint"),
                keywords: ["git", "checkpoint", "snapshot", "save", "capture", "stash"],
                category: .tab, symbol: "camera",
                targets: [.tab],
                surfacePlan: plan
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ActionCatalog", bundle: .module)
    }
}
