import CmuxNextActions
import CmuxNextPalette

/// Search Tabs (`tab.search`, Cmd-Shift-A; `palette.goToTab` is an alias):
/// the palette page over every tab with recently closed tabs below.
/// - With a tab target (Go to Tab from a script, an app's `tab.focus`) it
///   focuses that tab: the action's purpose is focus.
/// - Keyboard, menu and palette runs open the page (with `query` typed when
///   given). A CLI or MCP run opens it only with `focus: true`, because it
///   takes the keyboard; agents read results from `tabs.search`.
enum TabSearchHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let source = AppTabSearchSource(services: services)
        let live = TabSearchLiveUpdates()
        let page = { (query: String) -> PalettePageSpec in
            let spec = PalettePageSpec.tabSearch(source: source, query: query)
            live.follow(source, in: services.palette.model)
            return spec
        }
        services.palette.sources.actionPages["tab.search"] = { page("") }
        registry.bind("tab.search", run: { invocation in
            if let target = invocation.target, target.kind == .tab {
                return TabHandlers.reveal(tabID: target.id, ctx: context)
            }
            guard invocation.allowsViewChange else { throw ActionFailure(message: TabSearchAppStrings.needsFocus) }
            services.palette.show(page: page(invocation["query"]?.stringValue ?? ""), relativeTo: context.activeWindow?.window)
        })
    }
}
