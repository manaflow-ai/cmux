import CmuxNextDaemon

extension PaneController {
    /// An app tab (`app-screens-v1`): the app's own page, mounted through the
    /// app supervisor, as a store page tab. Nil while the app has no page here
    /// (not installed, hidden, or the supervisor is unreachable).
    func appTabContent(_ tab: TabModel) -> TabContent? {
        guard let app = tab.appTab,
              let provider = services.apps.pageProvider(appID: app.app, codeRouterAsPage: false) else { return nil }
        return services.pages.view(forStoreTab: tab, page: provider.page, in: daemon.store,
                                   window: state.flatMap { services.windows.controller(for: $0.id) })
            .map(TabContent.page)
    }
}
