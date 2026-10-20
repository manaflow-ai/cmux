import CmuxNextActions

/// Task Manager (`palette.openTaskManager`: palette, Window menu, `cmux app
/// task-manager`) and Kill Process (`taskManager.killProcess`: the page's
/// row menu and button, `cmux app kill-process <pid> --confirm`). Kill
/// Process is destructive, so every run asks first or needs `confirm`.
enum TaskManagerHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(services.taskManager) // at launch, so a restored tab finds it
        registry.bind("palette.openTaskManager", run: { invocation in
            try services.taskManager.show(focus: invocation.allowsViewChange)
        })
        registry.bind("taskManager.killProcess", run: { invocation in
            let text = invocation["process"]?.stringValue
            try services.taskManager.kill(services.taskManager.process(text))
        })
    }
}
