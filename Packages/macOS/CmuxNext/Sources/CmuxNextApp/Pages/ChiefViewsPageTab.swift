import CmuxNextActions
import CmuxNextChiefViews
import CmuxNextPages

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
        services.pages.register(WebPageTab(page, symbol: ChiefViewsPage.symbol, title: ChiefViewsPage.title) {
            ChiefViewsPage(host: host).makeView()
        })
        registry.bind(ChiefViewsPage.actionID, unavailable: { ChiefViewsPage.unavailableReason }, invoke: { [weak services] invocation in
            if let services { _ = services.pages.show(page, in: services.windows.active, focus: invocation.allowsViewChange) }
        })
        bindGalleryStage(into: registry, context: context)
    }

    static let galleryStage = InternalPageID(rawValue: "gallery-stage")

    /// Gallery Stage (``GalleryStageTabs``, CmuxNextPages), the other DEV gallery: one more page tab per run.
    static func bindGalleryStage(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services, stages = GalleryStageTabs()
        services.pages.register(WebPageTab(galleryStage, symbol: GalleryStageTabs.symbol, title: GalleryStageTabs.title, view: { stages.view(for: $0) }))
        registry.bindEffect(ActionID(rawValue: GalleryStageTabs.actionID), unavailable: { GalleryStageTabs.unavailableReason }) { [weak services] invocation in
            let refusal = stages.open(entry: invocation["entry"]?.stringValue, variant: invocation["variant"]?.stringValue) {
                services?.pages.openNew(galleryStage, in: services?.windows.active, focus: invocation.allowsViewChange) != nil
            }
            return refusal.map { ActionEffect.refused($0) } ?? .done
        }
    }
}
