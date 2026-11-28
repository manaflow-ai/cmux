import AppKit
import CmuxNextActions
import CmuxNextFeed
import CmuxNextIcons

extension InternalPageID {
    /// The wide inbox view of the one feed model.
    static let inbox = InternalPageID(rawValue: "inbox")
}

/// Owns the wide Inbox page. It is a view on `FeedService.model`, not a
/// second store, and therefore shares owner events, triage intents and the
/// menu-bar feed panel.
@MainActor
final class FeedPageService: InternalPageProvider {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Opens the Inbox in the active window without activating it for agent
    /// or socket callers when `focus` is false.
    func open(focus: Bool) throws {
        guard let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        services.feed.startIfSignedIn()
        guard services.pages.show(.inbox, in: window, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    var page: InternalPageID { .inbox }
    var title: String { FeedHostView.paneTitle }
    var symbol: String { "tray" }
    var icon: IconName? { .inbox }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let feed = services.feed
        FeedGitHubActions.install(on: feed.model, services: services)
        return FeedHostView(model: feed.model, layoutOverride: .inbox)
    }
}
