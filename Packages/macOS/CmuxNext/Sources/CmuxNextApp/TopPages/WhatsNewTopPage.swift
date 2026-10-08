import AppKit
import CmuxNextIcons
import CmuxNextUpdater
import SwiftUI

/// The page's provider: one SwiftUI page per window, over the one center.
@MainActor
final class WhatsNewTopPage: InternalPageProvider {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    var page: InternalPageID { .whatsNew }
    var title: String { WhatsNewPageStrings.title }
    var symbol: String { "sparkles" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        return NSHostingView(rootView: WhatsNewPageHost(center: services.updater.whatsNew, actions: WhatsNewPage.actions(services)))
    }
}

/// Redraws when the center's presented documents change (opened again).
struct WhatsNewPageHost: View {
    let center: WhatsNewCenter
    let actions: WhatsNewPageActions

    var body: some View {
        WhatsNewPageView(content: WhatsNewPageContent(documents: center.presented, canTry: WhatsNewPage.canTry),
                         actions: actions)
    }
}
