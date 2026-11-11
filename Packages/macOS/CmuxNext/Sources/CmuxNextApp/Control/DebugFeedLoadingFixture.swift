#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextFeed
import CmuxNextSettings

/// DEBUG ONLY: `debug.feed_loading_fixture.open {view: list | inbox | reports}` opens a page tab of
/// the active window with the real Feed views over a ``FeedModel`` whose owner has not answered
/// and whose reports mailbox was not read (``FeedModel/captureUnread()``), for captures of the
/// loading states (ui-state-fixes M4): the list's and the Inbox's "Loading…", the reports basket's
/// "Loading reports…". Compiled out of Release with this whole file.
extension InternalPageID {
    static let feedLoadingFixture = InternalPageID(rawValue: "feed-loading-fixture")
}

@MainActor
final class DebugFeedLoadingFixture: InternalPageProvider {
    enum View: String { case list, inbox, reports }

    /// What the next tab shows.
    var next = View.list
    private var models: [String: FeedModel] = [:]

    var page: InternalPageID { .feedLoadingFixture }
    var title: String { FeedHostView.paneTitle }
    var symbol: String { "tray" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let model = FeedModel.captureUnread()
        models[key] = model
        switch next {
        case .list: return FeedHostView(model: model, layoutOverride: .list)
        case .inbox: return FeedHostView(model: model, layoutOverride: .inbox)
        case .reports: return model.captureReportsBasket()
        }
    }

    func tabClosed(_ key: String) {
        models.removeValue(forKey: key)?.stop()
    }

    static func open(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let view = View(rawValue: params["view"]?.stringValue ?? "list") else {
            return .object(["error": .string("view must be list, inbox or reports")])
        }
        if services.pages.provider(.feedLoadingFixture) == nil { services.pages.register(DebugFeedLoadingFixture()) }
        (services.pages.provider(.feedLoadingFixture) as? DebugFeedLoadingFixture)?.next = view
        let shown = services.pages.openNew(.feedLoadingFixture, in: services.windows.active, focus: true)
        return .object(["ok": .bool(shown != nil), "view": .string(view.rawValue)])
    }
}
#endif
