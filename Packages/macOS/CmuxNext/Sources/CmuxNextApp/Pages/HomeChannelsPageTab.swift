import AppKit
import CmuxNextHibernation
import CmuxNextPages

/// The channels Home as an internal page tab, one per window: a pane tab, so it sits next to the
/// native Home (and any other tab) in a split. Opened by "Open Channels" (palette, File menu,
/// `cmux home channels`).
@MainActor
enum HomeChannelsPageTab {
    /// Never discarded (`memoryDiscardInternalPages`): its composers keep unsent text in the page's
    /// own state only, which a new page cannot show again. Chrome never discards a page with form
    /// input (chrome/browser/performance_manager/policies/discard_eligibility_policy.cc,
    /// `CannotDiscardReason::kFormInteractions`).
    static let discardPolicy = ContentDiscardPolicy.never

    static func make(_ services: AppServices) -> WebPageTab {
        WebPageTab(.homeChannels, symbol: "number", title: HomeChannelsStrings.title, discardPolicy: discardPolicy) { [weak services] in
            guard let services, let view = PageFactory(services: services).homeChannelsWebPage() else { return nil }
            view.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
            return view
        }
    }

    @discardableResult
    static func open(_ services: AppServices, focus: Bool = true) -> Bool {
        if services.pages.provider(.homeChannels) == nil { services.pages.register(make(services)) }
        return services.pages.show(.homeChannels, in: services.windows.active, focus: focus) != nil
    }
}

nonisolated enum HomeChannelsStrings {
    static var title: String { String(localized: "homeChannels.page.title", defaultValue: "Channels", table: "Handlers", bundle: .module) }
}
