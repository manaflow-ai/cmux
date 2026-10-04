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

    /// The views currently shown (occlusion holes).
    var shown: [NSView] {
        [errorView, goneView, unresponsiveView].filter { !$0.isHidden && $0.superview != nil }
    }

    /// Adds the views to `parent` over `content`, and routes their buttons
    /// to the current tab.
    func install(in parent: NSView, over content: NSView, tab: @escaping () -> (any BrowserTab)?) {
        for view in [errorView, goneView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        parent.addSubview(unresponsiveView)
        NSLayoutConstraint.activate([
            unresponsiveView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            unresponsiveView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            unresponsiveView.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 8),
        ])
        errorView.isHidden = true
        goneView.isHidden = true
        unresponsiveView.isHidden = true
        errorView.onRetry = { tab()?.reload() }
        errorView.onProceed = { (tab() as? any BrowserCertificateBypassing)?.proceedPastCertificateError() }
        errorView.onBack = {
            guard let tab = tab() else { return }
            // Nowhere to go back to (the bad page was the first): a blank page.
            if tab.state.canGoBack { tab.goBack() } else if let blank = URL(string: BrowserNewTabPage.blankURL) { tab.load(blank) }
        }
        goneView.onReload = { tab()?.reload() }
        unresponsiveView.onWait = { (tab() as? any BrowserHangAnswering)?.answerUnresponsivePage(terminate: false) }
        unresponsiveView.onExit = { (tab() as? any BrowserHangAnswering)?.answerUnresponsivePage(terminate: true) }
    }

    func render(_ state: BrowserTabState) {
        if let exit = state.processExit {
            goneView.show(exit)
        } else if !goneView.isHidden {
            goneView.isHidden = true
        }
        if state.processExit == nil, let error = state.loadError {
            errorView.show(error)
        } else if !errorView.isHidden {
            errorView.isHidden = true
        }
        unresponsiveView.isHidden = !state.isUnresponsive
    }
}
