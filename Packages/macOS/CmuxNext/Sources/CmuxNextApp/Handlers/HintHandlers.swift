import CmuxNextActions

/// Click by Hint (`hints.show`, Cmd-J; ``WindowHintController``). A preview
/// feature until styled: without `labs.previewFeatures` the action is
/// unavailable everywhere, so Cmd-J reaches the focused view as before.
enum HintHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("hints.show", unavailable: { [weak services] in
            services?.settings?.snapshot.previewFeatures == true ? nil : WindowHintStrings.preview
        }, invoke: { [weak services, weak registry] _ in
            guard let services, let controller = services.windows.active else { return }
            if !services.windowHints.toggle(in: controller) { registry?.refuse(WindowHintStrings.nothing) }
        })
    }
}
