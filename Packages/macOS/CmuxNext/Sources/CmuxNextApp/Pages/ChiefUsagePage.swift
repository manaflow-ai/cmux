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
@MainActor
final class ChiefUsagePageTab: InternalPageProvider {
    static let actionID: ActionID = "chief.openUsage"
    /// The Chief row menu's item title in Home ("Usage…").
    static var menuTitle: String { ChiefUsagePageProvider.menuTitle }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        // The bundle and the environment do not change while the app runs: resolved once.
        let tool = ChiefUsageTool.resolve()
        let hasLocalChief = tool != nil || HomeBrainHost.canStart()
        services.pages.register(ChiefUsagePageTab(services: services, tool: tool)) // at launch, so a restored tab finds it
        registry.bind(actionID, unavailable: {
            hasLocalChief ? nil : ChiefUsagePageProvider.noLocalChief
        }, invoke: { [weak services] invocation in
            if let services { _ = services.pages.show(.chiefUsage, in: services.windows.active, focus: invocation.allowsViewChange) }
        })
    }

    private weak var services: AppServices?
    private let tool: ChiefUsageTool?
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices, tool: ChiefUsageTool?) {
        self.services = services
        self.tool = tool
    }

    var page: InternalPageID { .chiefUsage }
    var title: String { ChiefUsagePageProvider.title }
    var symbol: String { "dollarsign.circle" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        // One `optchat-chief usage` run per call, off the main actor; no tool answers unavailable.
        let tool = tool
        let muxHome = HomeBrainHost.muxHome(tag: services?.environment.tag)
        let provider = ChiefUsagePageProvider { arguments in
            guard let tool else { return nil }
            return try await tool.run(arguments, muxHome: muxHome)
        }
        guard let view = PageWebView(descriptor: .chiefUsage, routes: [PageRoute(prefix: "cmux.chief_usage.", provider: provider)]) else {
            return NSView()
        }
        pages[key] = view
        return view
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }
}
