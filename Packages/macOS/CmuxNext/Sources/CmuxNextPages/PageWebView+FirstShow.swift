import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import WebKit

/// What a page view needs to start its document: the Chromium host the engine decision may use,
/// when the open was asked for (the start of its `webui.open` slice), and why its Chromium page starts.
@MainActor struct PageFirstShowStart {
    let chromium: (any PageChromiumHosting)?
    let requested: TimeInterval
    let origin: PageChromiumOrigin

    /// The start of a page that waited, now: it shows (`shown`), or startup completed while it did not
    /// (``PageChromiumOrigin/restoreHidden``). A page that shows while the launch runs is
    /// ``PageChromiumOrigin/restoreVisible``, one that shows after it ``PageChromiumOrigin/user``.
    func now(shown: Bool) -> PageFirstShowStart {
        let origin: PageChromiumOrigin = !shown ? .restoreHidden : chromium?.pendingLaunch != nil ? .restoreVisible : .user
        return PageFirstShowStart(chromium: chromium, requested: ProcessInfo.processInfo.systemUptime, origin: origin)
    }
}

/// The visibility node a page waiting for its first show follows, and its subscription to it.
@MainActor struct PageFirstShowWatch {
    weak var node: VisibilityNode?
    let subscription: VisibilitySubscription
}

// No renderer before the first show (p07-memory-048, feature `pageRendererAtFirstShow`). A page
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
// At launch (p08-startup-041, feature `chromiumPagesLaunchOrigin`) a Chromium page waits the same
// way: one that shows starts Chromium after the first frame (``PageChromiumOrigin/restoreVisible``),
// one that does not starts once startup completed (``PageChromiumOrigin/restoreHidden``), and until
// then shows its pane's theme background. Chrome's startup goal is the first visible WebContents;
// restored tabs that do not show load after it (chrome/browser/sessions/tab_loader.cc).
extension PageWebView {
    /// True while the page waits for its first show (at launch: or startup's completion) to start its document.
    public var awaitsFirstShow: Bool { firstShowStart != nil }

    /// Whether a window in `visibility` shows its pages: visible, or, in an automation launch that
    /// draws covered windows (``WindowDrawPolicy/drawsWhenOccluded``), occluded too.
    nonisolated static func windowShowsPages(_ visibility: Visibility, drawsWhenOccluded: Bool) -> Bool {
        visibility == .visible || (drawsWhenOccluded && visibility == .occluded)
    }

    /// Reads again whether a page that waits for its first show shows now; the view calls it when
    /// its window, superview, hidden state or node changes, and its node when that flips. A shown
    /// page starts its document; otherwise it follows its node.
    func checkFirstShow() {
        guard firstShowStart != nil else { return }
        guard let window else {
            firstShowWatch = nil
            return
        }
        let node = visibilityNode ?? WindowVisibilitySource.of(window).node
        if !isHidden, Self.windowShowsPages(node.effective, drawsWhenOccluded: WindowDrawPolicy.drawsWhenOccluded) {
            startAtFirstShow()
            return
        }
        guard firstShowWatch?.node !== node else { return }
        firstShowWatch = PageFirstShowWatch(node: node, subscription: node.subscribe(owner: "PageWebView.firstShow") { [weak self] _ in
            self?.checkFirstShow()
        })
    }

    /// The page shows (`shown`), or startup completed: a page that waited starts its document.
    func startAtFirstShow(shown: Bool = true) {
        guard let start = firstShowStart else { return }
        firstShowStart = nil
        firstShowWatch = nil
        scriptTarget.hasDocument = true
        startDocument(start.now(shown: shown))
    }

    /// Starts the document at ``route`` in the engine ``engineDecision`` picked.
    func startDocument(_ start: PageFirstShowStart) {
        traceOpenRequested(.newView, constructedSince: start.requested)
        if engineDecision.engine == .cef, let hosting = start.chromium {
            startChromium(hosting: hosting, origin: start.origin)
        } else {
            traceMark(.navigationStart)
            webView.load(URLRequest(url: descriptor.url(route: route)))
        }
    }
}
