import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextFeed
import CmuxNextIcons
import Foundation

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
    /// Sends report replies off the main thread.
    private let replies: AcpmuxReplySender

    init(services: AppServices, replies: AcpmuxReplySender = AcpmuxReplySender()) {
        self.services = services
        self.replies = replies
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
        feed.model.place = FeedPlace.lookup(services.daemon.store.place)
        let layout: FeedLayout = FeedTunables.reportsBasket.value ? .reportsBasket : .inbox
        let replies = replies
        // Resolved once at startup: a reply runs no executable lookup or signature check.
        let environment = feed.acpmuxEnvironment
        return FeedHostView(model: feed.model, layoutOverride: layout) { reply in
            // A report poster's authenticated identity is its ACP session. A
            // human reply intentionally wakes that session, unlike delivery
            // into the reports basket. The feed owner remains the source of
            // report rows; the command is a bounded local adapter for Labs.
            // The process runs off the main thread, to its exit or deadline (AcpmuxReplySender).
            await replies.send(session: reply.session, text: reply.text, promptID: reply.promptID, environment: environment)
        }
    }
}
