import AppKit
import CmuxNextDesign

/// The content-area status views of a browser pane, over the page: the load
/// error page, the sad tab (the page's process ended) and the "Page
/// unresponsive" card. Owned by `BrowserChromeView`, which adds their frames
/// to the page's occlusion rects so native UI shows above child-window
/// pages.
@MainActor
final class PageStatusViews {
    let errorView = LoadErrorView()
    let goneView = PageGoneView()
    let unresponsiveView = PageUnresponsiveView()
    /// Runs a warning page button through the action registry (the App
    /// installs it); true when it ran there.
    var certificateWarningRouter: ((CertificateWarningCommand) -> Bool)?
    /// The view the status views are in; a shown card asks it for a layout.
    private weak var parent: NSView?
    /// The tab whose state the views show (``render(tab:)``); its crash page may show before the next render.
    private weak var shownTab: (any BrowserTab)?

    /// The views currently shown (occlusion holes).
    var shown: [NSView] {
        [errorView, goneView, unresponsiveView].filter { !$0.isHidden && $0.superview != nil }
    }

    /// Adds the views to `parent`, and routes their buttons to the current
    /// tab. The parent places them over its page area with
    /// `layout(over:)` from its own `layout()`.
    func install(in parent: NSView, tab: @escaping () -> (any BrowserTab)?) {
        for view in [errorView, goneView, unresponsiveView] as [NSView] {
            parent.addSubview(view)
        }
        self.parent = parent
        errorView.isHidden = true
        goneView.isHidden = true
        unresponsiveView.isHidden = true
        errorView.onRetry = { tab()?.reload() }
        // The warning page's buttons run their registry action when routed.
        let send: (CertificateWarningCommand) -> Void = { [weak self] command in
            if let router = self?.certificateWarningRouter, router(command) { return }
            if let tab = tab() { command.perform(on: tab) }
        }
        errorView.onProceed = { send(.proceed) }
        errorView.onBack = { send(.goBack) }
        goneView.onReload = { tab()?.reload() }
        unresponsiveView.onWait = { (tab() as? any BrowserHangAnswering)?.answerUnresponsivePage(terminate: false) }
        unresponsiveView.onExit = { (tab() as? any BrowserHangAnswering)?.answerUnresponsivePage(terminate: true) }
    }

    /// Shows `tab`'s state, and shows its crash page as soon as its process ends
    /// (``BrowserCrashPageHosting``): the chrome renders the tab it binds through here.
    func render(tab: any BrowserTab) {
        shownTab = tab
        if let hosting = tab as? any BrowserCrashPageHosting { hosting.crashPagePresenter = self }
        render(tab.state)
    }

    func render(_ state: BrowserTabState) {
        if let exit = state.processExit {
            goneView.show(exit)
        } else if !goneView.isHidden {
            goneView.isHidden = true
        }
        // cmux's error page or certificate warning, unless the engine draws
        // its own (Chromium's net error page and interstitial).
        if state.processExit == nil, let error = state.loadError, !error.engineShowsPage {
            errorView.show(error)
        } else if !errorView.isHidden {
            errorView.isHidden = true
        }
        if unresponsiveView.isHidden == state.isUnresponsive {
            unresponsiveView.isHidden = !state.isUnresponsive
            parent?.needsLayout = true // invalidate: the card shows or hides; the parent places it
        }
    }

    /// Places the views over `page`, the page area in the parent's
    /// coordinates: the error page and the sad tab cover it, the "Page
    /// unresponsive" card (only while shown) is centered in it.
    func layout(over page: CGRect) {
        place(errorView, at: page)
        place(goneView, at: page)
        guard !unresponsiveView.isHidden else { return }
        let size = unresponsiveView.size(fittingWidth: max(page.width - Self.cardMargin * 2, 0))
        place(unresponsiveView, at: Self.centered(size, in: page))
    }

    /// The least room between the "Page unresponsive" card and the page's sides.
    static let cardMargin: CGFloat = 8

    /// A rect of `size` centered in `area`, on whole points.
    nonisolated static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: (area.midX - size.width / 2).rounded(.down), y: (area.midY - size.height / 2).rounded(.down),
               width: size.width, height: size.height)
    }

    private func place(_ view: NSView, at frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }
}

extension PageStatusViews: BrowserCrashPagePresenter {
    /// `tab`'s process (or the Chromium Host) ended in this turn: its crash page shows in this turn's
    /// frame, while the tab is the one shown here. The parent's layout, before this turn's commit,
    /// places it and gives a child-window page its hole there.
    func showCrashPage(of tab: any BrowserTab) {
        guard shownTab === tab, tab.state.processExit != nil else { return }
        render(tab.state)
        parent?.needsLayout = true // invalidate: the crash page shows; the parent's layout makes its page hole
    }
}
