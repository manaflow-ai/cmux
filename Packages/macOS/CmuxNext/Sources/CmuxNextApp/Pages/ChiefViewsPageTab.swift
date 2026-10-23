import CmuxNextActions
import CmuxNextChiefViews

/// The Chief view gallery (``ChiefViewsPage``, CmuxNextChiefViews) as a page tab: in the home
/// workspace it lands in Home's right column beside the Chief dock. The app passes its machines
/// and its navigation; the target serves the page.
enum ChiefViewsPageTab {
    static let page = InternalPageID(rawValue: "chief-views")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let host = ChiefViewsHost(
            workspaces: { [weak services] in services?.machines.allWorkspaces ?? [] },
            machineName: { [weak services] daemon in services.flatMap { ControlSessions.machineName(daemon, machines: $0.machines) } },
            openChat: { [weak services] in try services.map(DeepLinkNavigator.init)?.open(DeepLink(.session($0, turn: nil)), background: false) },
            revealTab: { [weak services] in services?.revealTab($0) ?? false },
            openURL: { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) })
        let lowPowerMode = services.lowPowerMode
        services.pages.register(WebPageTab(page, symbol: ChiefViewsPage.symbol, title: ChiefViewsPage.title) {
            ChiefViewsPage(host: host, lowPowerMode: lowPowerMode).makeView()
        })
        registry.bind(ChiefViewsPage.actionID, unavailable: { ChiefViewsPage.unavailableReason }, invoke: { [weak services] invocation in
            if let services { _ = services.pages.show(page, in: services.windows.active, focus: invocation.allowsViewChange) }
        })
    }
}
