import CmuxNextActions

/// Agent Stats (`stats.show`, hq#1920; ``StatsPageTab``). A preview feature until styled: without
/// `labs.previewFeatures` the action is unavailable everywhere.
enum StatsHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        // Registered at launch so a restored Stats tab finds its provider.
        services.pages.register(StatsPageTab(services: services))
        registry.bind("stats.show", unavailable: { [weak services] in
            services?.settings?.snapshot.previewFeatures == true ? nil : StatsStrings.preview
        }, invoke: { [weak services] _ in
            guard let services else { return }
            StatsPageTab.open(services)
        })
    }
}
