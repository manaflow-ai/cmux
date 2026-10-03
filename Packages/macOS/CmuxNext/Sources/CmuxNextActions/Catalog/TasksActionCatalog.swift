// Tasks (plans/cmux-next/tasks.md section 14, slice 4): the Tasks pane is
// an internal page (`local-page:tasks:<uuid>`). Titles live in
// TasksActions.xcstrings. Task ops themselves (`task.create`, `task.update`,
// `task.delegate`, ...) are the Tasks owner's catalog (`cmux task ...`);
// these actions only show the page. New Task waits for a create flow in
// the pane.

nonisolated enum TasksActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "tasks.show", title: t("action.tasks.show", "Open Tasks"),
                keywords: ["tasks", "issues", "todo", "inbox", "board", "backlog", "agents"],
                category: .agents, symbol: "checklist", surfaces: [.palette, .keyboard],
                cliName: "tasks open",
                surfacePlan: ActionSurfacePlan(
                    // A tab of the active window; automation opens it without
                    // moving focus. Agents read tasks through `cmux task list`.
                    cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "tasks.showMine", title: t("action.tasks.showMine", "My Tasks"),
                keywords: ["tasks", "mine", "assigned", "issues", "todo"],
                category: .agents, symbol: "person.crop.circle.badge.checkmark", surfaces: [.palette, .keyboard],
                cliName: "tasks mine",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "TasksActions", bundle: .module)
    }
}
