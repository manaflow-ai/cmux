import CmuxNextSettings

extension GlobalHotKeyService {
    /// The app's service: the catalog's global hot keys, with Show/Hide All
    /// Windows gated by `app.globalHotKey` from the live settings.
    static func app(_ services: AppServices) -> GlobalHotKeyService {
        GlobalHotKeyService(registry: services.registry, showHideEnabled: { [weak services] in
            services?.settings?.snapshot.globalHotKey ?? CmuxConfigSnapshot.globalHotKeyFallback
        })
    }
}
