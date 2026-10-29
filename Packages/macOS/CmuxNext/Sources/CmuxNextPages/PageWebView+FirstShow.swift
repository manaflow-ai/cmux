import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import WebKit

/// What a page view needs to start its document: the Chromium host the engine decision may use,
/// when the open was asked for (the start of its `webui.open` slice), and who asked for it.
@MainActor struct PageFirstShowStart {
    let chromium: (any PageChromiumHosting)?
    var requested: TimeInterval
    let opener: PageOpenOrigin
    /// A restored page that waits while the launch runs, not for its first show alone: it also starts at its launch
    /// turn (``PageChromiumHosting/startHidden(when:_:)``), asked once, when it is in a window and does not show.
    var atLaunchTurn = false

    /// The origin its Chromium page is made with now: the opener's; a restored page's is the launch order's, by
    /// whether it shows (`shown`). The engine's launch order is the only wait (``PageChromiumOrigin``).
    func chromiumOrigin(shown: Bool) -> PageChromiumOrigin {
        switch opener {
        case .user: .user
        case .automation: .automation
        case .launchRestore: chromium?.restoredOrigin(isShown: shown) ?? .user
        }
    }
}

/// The visibility node a page waiting for its first show follows, and its subscription to it.
@MainActor struct PageFirstShowWatch {
    weak var node: VisibilityNode?
    let subscription: VisibilitySubscription
}

// No renderer before the first show (feature `pageRendererAtFirstShow`). A page
// opened hidden (a background tab, a tab of a hidden workspace) keeps its view, router and bridge,
// and starts its document, and with it its WebKit WebContent process or Chromium renderer, only
// when it first shows. Until then it makes no engine call: its scripts are dropped
// (``PageScriptTarget/hasDocument``) and its function calls and pictures answer nothing. This is
// Chrome's delayed load of a tab that has not shown: the WebContents exists, its renderer does
// not; `NavigationControllerImpl::SetNeedsReload` marks it, and `WebContentsImpl::WasShown` ->
// `NavigationControllerImpl::SetActive` -> `LoadIfNecessary` loads it
// (content/browser/renderer_host/navigation_controller_impl.cc). WasShown follows real visibility,
// occlusion included (`WebContentsImpl::UpdateWebContentsVisibility`), so a page counts as shown
// only when its node in the visibility tree (p06-scheduler.md B) says so: its tab's node once a pane
// shows it (``followAppearance(_:node:)``: tab, pane, workspace, window, app), else its window's
// ``WindowVisibilitySource`` node.
//
// At launch a Chromium page the launch restored (``PageOpenOrigin/launchRestore``) waits the
// same way while the launch runs, and shows its pane's theme background meanwhile (the page is transparent).
// When it shows it asks for its Chromium page at once as ``PageChromiumOrigin/restoreVisible``, and the engine's
// launch order (`CEFLaunchDeferral`, feature `cefLaunchOrigin`) starts it in the first afterFirstFrame slot; one
// that does not show starts at its launch turn (``PageChromiumHosting/startHidden(when:_:)``: it shows, or the
// afterStartup post), and after completion no origin waits. Both waits are the engine's launch order's: one path.
// Chrome's startup goal is the first visible WebContents; restored tabs that do not show load after it
// (chrome/browser/sessions/tab_loader.cc).
extension PageWebView {
    /// True while the page waits for its first show (a restored one at launch: or its launch turn) to start its document.
    public var awaitsFirstShow: Bool { firstShowStart != nil }

    /// Whether a window in `visibility` shows its pages: visible, or, in an automation launch that
    /// draws covered windows (``WindowDrawPolicy/drawsWhenOccluded``), occluded too.
    nonisolated static func windowShowsPages(_ visibility: Visibility, drawsWhenOccluded: Bool) -> Bool {
        visibility == .visible || (drawsWhenOccluded && visibility == .occluded)
    }

    /// The node the page's first show follows, and whether the page shows now; nil while it is in no window.
    private var firstShowNode: (node: VisibilityNode, shows: Bool)? {
        guard let window else { return nil }
        let node = visibilityNode ?? WindowVisibilitySource.of(window).node
        return (node, !isHidden && Self.windowShowsPages(node.effective, drawsWhenOccluded: WindowDrawPolicy.drawsWhenOccluded))
    }

    /// Reads again whether a page that waits for its first show shows now; the view calls it when
    /// its window, superview, hidden state or node changes, and its node when that flips. A shown
    /// page starts its document; otherwise it follows its node (a restored one at launch also asks for its launch turn).
    func checkFirstShow() {
        guard firstShowStart != nil else { return }
        guard let current = firstShowNode else {
            firstShowWatch = nil
            return
        }
        let node = current.node
        if current.shows {
            startAtFirstShow()
            return
        }
        if firstShowStart?.atLaunchTurn == true, let hosting = firstShowStart?.chromium {
            firstShowStart?.atLaunchTurn = false
            hosting.startHidden(when: node) { [weak self] in self?.startAtFirstShow(shown: self?.firstShowNode?.shows ?? false) }
        }
        guard firstShowWatch?.node !== node else { return }
        firstShowWatch = PageFirstShowWatch(node: node, subscription: node.subscribe(owner: "PageWebView.firstShow") { [weak self] _ in
            self?.checkFirstShow()
        })
    }

    /// The page shows (`shown`), or its launch turn came: a page that waited starts its document.
    func startAtFirstShow(shown: Bool = true) {
        guard var start = firstShowStart else { return }
        firstShowStart = nil
        firstShowWatch = nil
        scriptTarget.hasDocument = true
        start.requested = ProcessInfo.processInfo.systemUptime
        startDocument(start, origin: start.chromiumOrigin(shown: shown))
    }

    /// Starts the document at ``route`` in the engine ``engineDecision`` picked; a Chromium page is made with `origin`.
    func startDocument(_ start: PageFirstShowStart, origin: PageChromiumOrigin) {
        traceOpenRequested(isPooled ? .spare : .newView, constructedSince: start.requested)
        if engineDecision.engine == .cef, let hosting = start.chromium {
            startChromium(hosting: hosting, origin: origin)
        } else {
            traceMark(.navigationStart)
            webKit.view.load(URLRequest(url: descriptor.url(route: route)))
        }
    }
}
