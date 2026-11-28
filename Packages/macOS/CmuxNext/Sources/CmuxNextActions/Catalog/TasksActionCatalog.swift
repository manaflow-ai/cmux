// Tasks (plans/cmux-next/tasks.md section 14, slice 4): the Tasks pane is
// an internal page (`local-page:tasks:<uuid>`). Titles live in
// TasksActions.xcstrings. Task ops themselves (`task.create`, `task.update`,
// `task.delegate`, ...) are the Tasks owner's catalog (`cmux task ...`);
// these actions show the page. CLI names sit under the one `task` noun:
// the Rust CLI routes `cmux task open` and `cmux task mine --open-pane`
// here by CLI name.

nonisolated enum TasksActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "tasks.show", title: t("action.tasks.show", "Open Tasks"),
                keywords: ["tasks", "issues", "todo", "inbox", "board", "backlog", "agents"],
                category: .agents, symbol: "checklist", surfaces: [.palette, .keyboard],
                cliName: "task open",
                surfacePlan: ActionSurfacePlan(
                    // A tab of the active window; automation opens it without
                    // moving focus. Agents read tasks through `cmux task list`.
                    cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "tasks.new", title: t("action.tasks.new", "New Task"),
                keywords: ["tasks", "new", "create", "add", "issue", "todo"],
                category: .agents, symbol: "plus.circle", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(
                    // Focuses the pane's title field, which only a user run
                    // may do; agents create tasks with `cmux task create`.
                    cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "tasks.showMine", title: t("action.tasks.showMine", "My Tasks"),
                keywords: ["tasks", "mine", "assigned", "issues", "todo"],
                category: .agents, symbol: "person.crop.circle.badge.checkmark", surfaces: [.palette, .keyboard],
                cliName: "task mine",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "TasksActions", bundle: .module)
    }
}
