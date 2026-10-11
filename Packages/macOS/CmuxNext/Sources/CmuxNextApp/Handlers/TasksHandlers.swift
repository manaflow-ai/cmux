import CmuxNextActions
import CmuxNextTasks

/// Tasks actions (plans/cmux-next/tasks.md section 14, slice 4): both show
/// the Tasks page; a user run selects it and sets its scope, automation
/// opens it without changing focus or the view.
enum TasksHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(services.tasks)
        registry.bind("tasks.show", run: { invocation in
            try services.tasks.show(scope: .all, focus: invocation.allowsViewChange)
        })
        registry.bind("tasks.new", run: { invocation in
            try services.tasks.show(scope: nil, newTask: true, focus: invocation.allowsViewChange)
        })
        registry.bind("tasks.showMine", run: { invocation in
            try services.tasks.show(scope: .mine, focus: invocation.allowsViewChange)
        })
    }
}
