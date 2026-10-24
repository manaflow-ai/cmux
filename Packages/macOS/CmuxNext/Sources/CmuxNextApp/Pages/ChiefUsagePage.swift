import AppKit
import CmuxNextActions
import CmuxNextHomeEngine
import CmuxNextPages

extension InternalPageID {
    static let chiefUsage = InternalPageID(rawValue: "chief-usage")
}

/// The Chief Usage page (``ChiefUsagePageProvider``, chief-usage-analytics-DESIGN.md) as an
/// internal page tab, one per window. `chief.openUsage` (palette, the Chief's row menu in Home,
/// `cmux action run`) shows it: in the home workspace a page tab lands in the column beside the
/// Chief dock (`pageTabPane`), which is Home's right column. Unavailable in a build without a
/// local Chief (Release and RC bundle none).
enum ChiefUsagePageTab {
    static let actionID: ActionID = "chief.openUsage"
    /// The Chief row menu's item title in Home ("Usage…").
    static var menuTitle: String { ChiefUsagePageProvider.menuTitle }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        // The bundle and the environment do not change while the app runs: resolved once.
        let tool = ChiefUsageTool.resolve()
        let hasLocalChief = tool != nil || HomeBrainHost.canStart()
        // at launch, so a restored tab finds it; one `optchat-chief usage` run per call, off the
        // main actor, and no tool answers unavailable.
        let errors = services.errorJournal.journal
        services.pages.register(WebPageTab(.chiefUsage, symbol: "dollarsign.circle", title: ChiefUsagePageProvider.title) { [weak services] in
            let muxHome = HomeBrainHost.muxHome(tag: services?.environment.tag)
            let provider = ChiefUsagePageProvider { arguments in
                guard let tool else { return nil }
                return try await tool.run(arguments, muxHome: muxHome)
            }
            return PageWebView(descriptor: .chiefUsage, routes: [PageRoute(prefix: "cmux.chief_usage.", provider: provider)], errors: errors)
        })
        registry.bind(actionID, unavailable: {
            hasLocalChief ? nil : ChiefUsagePageProvider.noLocalChief
        }, invoke: { [weak services] invocation in
            if let services { _ = services.pages.show(.chiefUsage, in: services.windows.active, focus: invocation.allowsViewChange) }
        })
    }
}
