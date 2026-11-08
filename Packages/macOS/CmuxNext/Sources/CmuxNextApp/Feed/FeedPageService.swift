import AppKit
import CmuxNextActions
import CmuxNextIcons
import CmuxNextPages
import Foundation

extension InternalPageID {
    /// The wide inbox view of the Feed page.
    static let inbox = InternalPageID(rawValue: "inbox")
}

/// Owns the wide Inbox page: the Feed page (`cmux.feed`) on `#/inbox`. It is a view of the
/// daemon's feed client, as the Feed panel and the right sidebar's Feed are, so they share owner
/// events and triage.
@MainActor
final class FeedPageService: InternalPageProvider {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Opens the Inbox in the active window (unfocused when `focus` is false), on an item's `route`.
    func open(focus: Bool, route: String? = nil) throws {
        guard let window = services.windows.active, let view = services.pages.show(.inbox, in: window, focus: focus) else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
        if let route { (view.content as? PageWebView)?.open(route: route) }
    }

    var page: InternalPageID { .inbox }
    var title: String { Self.title }
    var symbol: String { "tray" }
    var icon: IconName? { .inbox }

    /// The Inbox tab's title.
    static var title: String { String(localized: "feed.inboxTitle", defaultValue: "Inbox", table: "Feed", bundle: .module) }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        PageFactory(services: services).feedWebPage(route: "#/inbox?surface=page") ?? NSView()
    }
}
