/// What one Chromium page view does after its Chromium browser ended (``PageChromiumEvent/ended``):
/// it waits for the helper-app supervisor (``PageChromiumHosting/supervisorOutcome()``,
/// plans/cmux-next/cef-helper-app-DESIGN.md). Then a shown page reopens in WebKit when the
/// supervisor gave up, or in a new Chromium page when Chromium runs again; a hidden page does that
/// when it shows. So the end of a browser under eight pages, one shown, makes one engine page.
///
/// Chrome's crashed background tab does the same: `NavigationControllerImpl::SetNeedsReload` marks
/// it, and `WebContentsImpl::WasShown` reloads it through `LoadIfNecessary`
/// (content/browser/renderer_host/navigation_controller_impl.cc).
///
/// The page view holds it (``PageWebView/chromiumRecovery``) from the end until the page shows in
/// an engine again, or closes.
@MainActor
final class PageChromiumRecovery {
    private weak var page: PageWebView?
    private let hosting: any PageChromiumHosting
    /// The supervisor's answer, once it came.
    private var outcome: PageChromiumSupervisorOutcome?
    /// The supervisor ask while it runs (tests await it).
    private(set) var wait: Task<Void, Never>?

    /// The page's Chromium browser ended: the page drops its Chromium page and its document now,
    /// and asks `hosting`'s supervisor what follows.
    ///
    /// - Parameters:
    ///   - page: The page view, which holds this object.
    ///   - hosting: The Chromium host the page's Chromium page came from.
    init(page: PageWebView, hosting: any PageChromiumHosting) {
        self.page = page
        self.hosting = hosting
        page.logger.error("page \(page.descriptor.id, privacy: .public): the Chromium browser ended; waiting for its supervisor")
        page.endChromium()
        page.router.reset()
        page.loaded = false
        // task-owner: PageChromiumRecovery; ends with the supervisor's answer, or cancel() when the page closes.
        wait = Task(priority: .userInitiated) { [weak self] in
            let outcome = await hosting.supervisorOutcome()
            guard !Task.isCancelled, let self else { return }
            self.wait = nil
            self.outcome = outcome
            self.pageShown()
        }
    }

    /// The page shows (in a window, with no hidden ancestor): once the supervisor answered, it
    /// reopens in WebKit or in a new Chromium page, and the page view lets this object go.
    func pageShown() {
        guard let outcome, let page, page.window != nil, !page.isHiddenOrHasHiddenAncestor else { return }
        let hosting = hosting
        page.chromiumRecovery = nil
        switch outcome {
        case .gaveUp: page.fallBackToWebKit(.chromiumFailed, detail: "the Chromium browser ended; its supervisor gave up")
        case .restarted: page.startChromium(hosting: hosting)
        }
    }

    /// The page closed or reopened another way: the answer does nothing, and the page view lets
    /// this object go.
    func cancel() {
        wait?.cancel()
        wait = nil
        outcome = nil
        if page?.chromiumRecovery === self { page?.chromiumRecovery = nil }
    }
}
