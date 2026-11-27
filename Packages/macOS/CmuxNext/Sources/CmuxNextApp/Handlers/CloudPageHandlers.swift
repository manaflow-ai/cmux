import CmuxNextActions

/// The Cloud page as a pane tab: `palette.openCloudPane` (the palette, the Window menu,
/// `cmux pane open-cloud-as` and MCP) shows the active window's Cloud tab or opens one. A user run
/// focuses it; automation opens it without moving focus. An optional `route` (the composer's Open
/// Cloud… passes `/get`, the storefront) is the page's URL fragment.
enum CloudPageHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let page = CloudPageService(services: context.services)
        context.services.pages.register(page)
        registry.bind("palette.openCloudPane", run: { invocation in
            try page.open(focus: invocation.allowsViewChange, route: invocation.arguments["route"]?.stringValue)
        })
    }
}
