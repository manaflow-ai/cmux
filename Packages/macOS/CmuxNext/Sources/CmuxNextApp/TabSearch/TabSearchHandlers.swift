import CmuxNextActions
import CmuxNextPalette

/// Search Tabs (`tab.search`, Cmd-Shift-A): the palette page over every
/// tab with recently closed tabs below. Keyboard, menu and palette runs
/// open it (with `query` typed when given). A CLI or MCP run opens it only
/// with `focus: true`, because it takes the keyboard; agents read results
/// from the `tabs.search` socket method instead (`TabSearchControl`).
enum TabSearchHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let source = AppTabSearchSource(services: services)
        services.palette.sources.actionPages["tab.search"] = { TabSearchPage.make(source: source) }
        registry.bind("tab.search", run: { invocation in
            guard invocation.allowsViewChange else { throw ActionFailure(message: TabSearchAppStrings.needsFocus) }
            let query = invocation["query"]?.stringValue ?? ""
            services.palette.show(page: TabSearchPage.make(source: source, query: query), relativeTo: context.activeWindow?.window)
        })
    }
}
