import CmuxNextActions

/// The one path that opens a top page (TOP-SECTION-ITEMS-ARE-PAGES): the
/// sidebar's top items, Cmd-1, `home.show` and `appStore.show` all come
/// here. A run without view-change permission (automation) shows nothing.
@MainActor
enum TopPages {
    /// Shows `route` in `state`'s window (else the active window) and gives
    /// the page the keyboard. Returns the provider key of an internal
    /// page's view (the App Store routes its listing through it), "" for
    /// Home, nil when nothing was shown.
    @discardableResult
    static func show(_ route: TopPageRoute, services: AppServices, in state: WindowState? = nil) -> String? {
        guard ActionRunScope.viewChangeAllowed(),
              let controller = state.flatMap({ services.windows.controller(for: $0.id) }) ?? services.windows.active else { return nil }
        guard controller.topPages.view(for: route, in: controller) != nil else { return nil }
        if controller.state.page != route {
            controller.state.page = route
            services.windows.recordSaver.stateDidChange(controller.state)
        }
        controller.showTopPage(route)
        controller.topPages.focus(route, in: controller.window)
        if case .home = route { return "" }
        return controller.topPages.key(for: route)
    }

    /// The provider of internal page `id`: a registered one, else an app's
    /// page registered on first use (CodeRouter, `app:<id>` pages).
    static func provider(_ id: InternalPageID, services: AppServices) -> (any InternalPageProvider)? {
        if let provider = services.pages.provider(id) { return provider }
        if id == .coderouter { return services.apps.pageProvider(appID: CodeRouterPageTab.appID) }
        let prefix = AppPanePage.pageID("").rawValue
        guard id.rawValue.hasPrefix(prefix) else { return nil }
        return services.apps.pageProvider(appID: String(id.rawValue.dropFirst(prefix.count)))
    }
}
