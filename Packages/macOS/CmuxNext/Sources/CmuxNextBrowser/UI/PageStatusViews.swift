import AppKit
import CmuxNextDesign

/// The content-area status views of a browser pane, over the page: the load
/// error page, the sad tab (the page's process ended) and the "Page
/// unresponsive" card. Owned by `BrowserChromeView`, which adds their frames
/// to the page's occlusion rects so native UI shows above child-window
/// pages.
///
/// Each view is made the first time it shows, as Chrome makes an infobar or
/// its sad tab only when one is needed: a new pane's first frame shows none
/// of them, and building all three was a third of Shift-Cmd-L's key turn (#32909).
@MainActor
final class PageStatusViews {
    /// The views made so far (nil until each first shows).
    private(set) var errorViewIfMade: LoadErrorView?
    private(set) var goneViewIfMade: PageGoneView?
    private(set) var unresponsiveViewIfMade: PageUnresponsiveView?
    /// Runs a warning page button through the action registry (the App
    /// installs it); true when it ran there.
    var certificateWarningRouter: ((CertificateWarningCommand) -> Bool)?

    private weak var parent: NSView?
    private weak var content: NSView?
    private var tab: () -> (any BrowserTab)? = { nil }

    /// The views currently shown (occlusion holes).
    var shown: [NSView] {
        ([errorViewIfMade, goneViewIfMade, unresponsiveViewIfMade] as [NSView?]).compactMap { $0 }
            .filter { !$0.isHidden && $0.superview != nil }
    }

    /// Where the views go when they first show: in `parent`, over `content`;
    /// their buttons act on the current tab.
    func install(in parent: NSView, over content: NSView, tab: @escaping () -> (any BrowserTab)?) {
        self.parent = parent
        self.content = content
        self.tab = tab
    }

    /// The error page, made and placed over the page on first use.
    var errorView: LoadErrorView {
        if let errorViewIfMade { return errorViewIfMade }
        let view = LoadErrorView()
        fill(view)
        let tab = tab
        view.onRetry = { tab()?.reload() }
        // The warning page's buttons run their registry action when routed.
        let send: (CertificateWarningCommand) -> Void = { [weak self] command in
            if let router = self?.certificateWarningRouter, router(command) { return }
            if let tab = tab() { command.perform(on: tab) }
        }
        view.onProceed = { send(.proceed) }
        view.onBack = { send(.goBack) }
        errorViewIfMade = view
        return view
    }

    /// The sad tab, made and placed over the page on first use.
    var goneView: PageGoneView {
        if let goneViewIfMade { return goneViewIfMade }
        let view = PageGoneView()
        fill(view)
        let tab = tab
        view.onReload = { tab()?.reload() }
        goneViewIfMade = view
        return view
    }

    /// The "Page unresponsive" card, made and centered on the page on first use.
    var unresponsiveView: PageUnresponsiveView {
        if let unresponsiveViewIfMade { return unresponsiveViewIfMade }
        let view = PageUnresponsiveView()
        if let parent, let content {
            view.translatesAutoresizingMaskIntoConstraints = false
            // Over the error page and the sad tab, under the page bars.
            let below = ([errorViewIfMade, goneViewIfMade] as [NSView?]).compactMap { $0 }
                .max { (parent.subviews.firstIndex(of: $0) ?? 0) < (parent.subviews.firstIndex(of: $1) ?? 0) }
            parent.addSubview(view, positioned: .above, relativeTo: below ?? content)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                view.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 8),
            ])
        }
        view.isHidden = true
        let tab = tab
        view.onWait = { (tab() as? any BrowserHangAnswering)?.answerUnresponsivePage(terminate: false) }
        view.onExit = { (tab() as? any BrowserHangAnswering)?.answerUnresponsivePage(terminate: true) }
        unresponsiveViewIfMade = view
        return view
    }

    /// Adds `view`, hidden, over the whole page.
    private func fill(_ view: NSView) {
        view.isHidden = true
        guard let parent, let content else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        // Under the page bars (find, prompt), which come after the page in the chrome's subviews.
        parent.addSubview(view, positioned: .above, relativeTo: content)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    func render(_ state: BrowserTabState) {
        if let exit = state.processExit {
            goneView.show(exit)
        } else if let gone = goneViewIfMade, !gone.isHidden {
            gone.isHidden = true
        }
        // cmux's error page or certificate warning, unless the engine draws
        // its own (Chromium's net error page and interstitial).
        if state.processExit == nil, let error = state.loadError, !error.engineShowsPage {
            errorView.show(error)
        } else if let shownError = errorViewIfMade, !shownError.isHidden {
            shownError.isHidden = true
        }
        if state.isUnresponsive {
            unresponsiveView.isHidden = false
        } else {
            unresponsiveViewIfMade?.isHidden = true
        }
    }
}
