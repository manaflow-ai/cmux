import AppKit
import CmuxNextActions
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
        let layout: FeedLayout = FeedTunables.reportsBasket.value ? .reportsBasket : .inbox
        return FeedHostView(model: feed.model, layoutOverride: layout) { [services] reportID, reply in
            // A report poster's authenticated identity is its ACP session. A
            // human reply intentionally wakes that session, unlike delivery
            // into the reports basket. The feed owner remains the source of
            // report rows; the command is a bounded local adapter for Labs.
            guard !reportID.isEmpty, let environment = QuitAgents.environment(services) else { return false }
            let process = Process()
            process.executableURL = environment.executable
            process.arguments = ["send", reportID, reply, "--no-wait", "--no-steer"]
            process.environment = ProcessInfo.processInfo.environment.merging(environment.childEnvironment) { _, value in value }
            do {
                try process.run()
                return true
            } catch {
                return false
            }
        }
    }
}
