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
    /// Loads a page that failed for the network again by itself while the error page is in sight (Chrome's
    /// `NetErrorAutoReloader`), instead of a Try Again the person would only ever press.
    let loadRetry = AutoRetry(owner: "browser.loadError")
    /// The phase last rendered: a failure counts once, when the phase turns to it.
    private var renderedPhase: BrowserLoadPhase?
    /// ``loadRetry`` started a load that has not been rendered failing yet (its start and failure can reach one
    /// render together, leaving the phase as it was).
    private var retryPending = false

    /// The views currently shown (occlusion holes).
    var shown: [NSView] {
        ([errorViewIfMade, goneViewIfMade, unresponsiveViewIfMade] as [NSView?]).compactMap { $0 }
            .filter { !$0.isHidden && $0.superview != nil }
    }

    /// The color of the status page that covers the whole page area now (the error page or the sad tab, opaque in
    /// `Palette.pageBackground`); nil when the page shows. A closing pane shows it (`BrowserChromeView.paneGround`).
    var coveringGround: CGColor? {
        ([goneViewIfMade, errorViewIfMade] as [NSView?]).lazy.compactMap { $0 }
            .first { !$0.isHidden && $0.superview != nil }?.layer?.backgroundColor
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
        view.onSightChanged = { [loadRetry] in loadRetry.setInSight($0) }
        loadRetry.setAttempt { [weak self] in
            guard let self, let tab = tab(), case .failed(let error) = tab.state.phase else { return }
            retryPending = true
            // The failed address, not the page still on screen: WebKit's reload after a failed provisional load
            // loads the committed page again. Loading the same address as the shown document replaces its entry.
            if let url = error.failingURL { tab.load(url) } else { tab.reload() }
        }
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

    /// Feeds ``loadRetry``: a network failure shown on the error page fails once per load; a load that commits or
    /// finishes succeeds; any other failure, or none, stops it.
    private func renderLoadRetry(_ state: BrowserTabState) {
        let phase = state.phase
        defer { renderedPhase = phase }
        switch phase {
        case .failed(let error):
            let reloads = state.processExit == nil && !error.engineShowsPage && !error.isCertificateError
                && error.isTransientNetworkFailure && !error.sentForm
            guard reloads else { retryPending = false; loadRetry.stop(); return }
            if phase != renderedPhase || retryPending { loadRetry.failed() }
            retryPending = false
        case .provisional:
            break
        case .committed, .finished, .idle:
            retryPending = false
            if loadRetry.isFailing { loadRetry.succeeded() }
        }
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
        // A load ``loadRetry`` started keeps the error page until it commits, as Chrome's error page stays the
        // committed document: the old page does not flash in at every attempt.
        let retrying = loadRetry.isFailing && state.phase == .provisional && state.processExit == nil
        if state.processExit == nil, let error = state.loadError, !error.engineShowsPage {
            errorView.show(error)
        } else if retrying, errorViewIfMade?.isHidden == false {
            // Still the error page.
        } else if let shownError = errorViewIfMade, !shownError.isHidden {
            shownError.isHidden = true
        }
        renderLoadRetry(state)
        if state.isUnresponsive {
            unresponsiveView.isHidden = false
        } else {
            unresponsiveViewIfMade?.isHidden = true
        }
    }
}
