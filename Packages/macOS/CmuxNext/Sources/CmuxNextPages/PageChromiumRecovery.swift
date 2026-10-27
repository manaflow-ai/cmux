import Foundation
import os

/// What a ``PageWebView`` does after its Chromium browser ended (``PageChromiumEvent/ended``,
/// p13-webui.md 3.H): it drops its Chromium page and its document, and waits for the Chromium
/// supervisor (``PageChromiumHosting/supervisorOutcome(then:)``, plans/cmux-next/cef-helper-app-DESIGN.md).
/// Once the supervisor answered, a shown page reopens in WebKit after its give-up, or in a new
/// Chromium page after its restart; a hidden page does the same when it shows. So the end of a
/// browser under eight pages, one shown, makes one WebKit engine, and only after the give-up.
///
/// Chrome treats a background tab whose renderer died the same way:
/// `NavigationControllerImpl::SetNeedsReload` marks it, and `WebContentsImpl::WasShown` reloads it
/// through `LoadIfNecessary` (content/browser/renderer_host/navigation_controller_impl.cc).
///
/// The page view holds it (``PageWebView/chromiumRecovery``) from the end until the page shows in an
/// engine again, or closes; a discard keeps it, so the discarded page's restore reopens it as the
/// answer says (``PageWebView/restoreDiscardedPage()``), never in a Chromium the supervisor gave up on.
@MainActor
final class PageChromiumRecovery {
    private weak var page: PageWebView?
    private let hosting: any PageChromiumHosting
    /// The supervisor's answer, once it came.
    private var outcome: PageChromiumSupervisorOutcome?
    /// The page closed or reopened another way: the answer does nothing.
    private var cancelled = false

    private init(page: PageWebView, hosting: any PageChromiumHosting) {
        self.page = page
        self.hosting = hosting
    }

    /// `page`'s Chromium browser ended: its Chromium page and document go now, and it asks the
    /// supervisor of the host that made the page what follows. A page with no host reopens in WebKit.
    ///
    /// - Parameter page: The page whose browser ended.
    static func browserEnded(_ page: PageWebView) {
        guard let hosting = page.chromiumHost else {
            return page.fallBackToWebKit(.chromiumFailed, detail: "the Chromium browser ended")
        }
        page.logger.error("page \(page.descriptor.id, privacy: .public): the Chromium browser ended; waiting for its supervisor")
        page.endChromium()
        // No engine shows a document until the answer: scripts sent meanwhile are dropped, and the
        // engine that shows the page next gets its theme and scale with its document.
        page.scriptTarget.bridge = nil
        page.router.reset()
        // The frozen engine page went with it: the providers run again, with no stream to resync.
        page.router.pageDidThaw()
        page.loaded = false
        let recovery = PageChromiumRecovery(page: page, hosting: hosting)
        page.chromiumRecovery = recovery
        hosting.supervisorOutcome { [weak recovery] outcome in recovery?.answered(outcome) }
    }

    private func answered(_ outcome: PageChromiumSupervisorOutcome) {
        guard !cancelled, self.outcome == nil else { return }
        self.outcome = outcome
        pageShown()
    }

    /// The page may show now (``PageWebView/setEngineVisible(_:)``, ``PageWebView/restoreDiscardedPage()``):
    /// once the supervisor answered and the page shows in its window, not discarded, it reopens in
    /// WebKit or in a new Chromium page, and the page view lets this object go.
    func pageShown() {
        guard let outcome, let page, page.isShownInWindow, !page.isDiscarded else { return }
        page.chromiumRecovery = nil
        switch outcome {
        case .gaveUp: page.fallBackToWebKit(.chromiumFailed, detail: "the Chromium browser ended; its supervisor gave up")
        case .restarted: page.startChromium(hosting: hosting, origin: .user) // it shows now: a person's, never a launch wait
        }
    }

    /// The page closed or reopened another way: the answer does nothing.
    func cancel() {
        cancelled = true
        outcome = nil
    }
}

/// What the Chromium supervisor did after a page's browser ended (``PageChromiumHosting/supervisorOutcome(then:)``).
public nonisolated enum PageChromiumSupervisorOutcome: Sendable, Equatable {
    /// Chromium runs again: the page can be made in it again.
    case restarted
    /// Chromium stays ended: the page reopens in WebKit.
    case gaveUp
}
