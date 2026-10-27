import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// What a page was last told about its loops, and the visibility node it follows for them
/// (``PageWebView/syncLoopVisibility(newDocument:)``).
@MainActor final class PageLoopVisibility {
    /// Whether the host tells this page (feature `hiddenPageLoops`).
    var enabled = false
    /// What the current document was last told; nil until it is told (a new document).
    var told: Bool?
    /// The node followed: the tab's, or the window's while no pane shows the page.
    weak var node: VisibilityNode?
    var flips: VisibilitySubscription?
    var rendering: VisibilitySubscription?
}

// Hidden and occluded pages run no loops (p03-rendering-120, feature `hiddenPageLoops`). The host
// tells the document whether a person can see it, `window.cmuxTheme.visibility(shown)` (WebTheme's
// bootstrap), at each new document and at each change: the engine was told it shows
// (``setEngineVisible(_:)``) and its node renders (visible, or held by a capture). The page then
// pauses its CSS animations and holds its animation-frame callbacks until it shows. Chrome stops the
// same work for a hidden or occluded WebContents (`WebContentsImpl::WasHidden` and `WasOccluded`,
// content/browser/web_contents/web_contents_impl.cc); the push covers what the engine cannot see: a
// window under an opaque cmux window of the same size (``WindowOcclusionFamily``, crbug.com/883031)
// and a document the engine still counts as visible.
extension PageWebView {
    /// Turns the push on for this page; ``WebUIHost/open(_:)`` and ``PageHostPool`` claims call it
    /// while the feature is on.
    package func stopLoopsWhileHidden() {
        guard !loopVisibility.enabled else { return }
        loopVisibility.enabled = true
        syncLoopVisibility(newDocument: true)
    }

    /// The script that tells the document whether it shows.
    nonisolated static func loopVisibilityScript(shown: Bool) -> String {
        "window.cmuxTheme && window.cmuxTheme.visibility && window.cmuxTheme.visibility(\(shown));"
    }

    /// Follows the page's node and tells the document when whether it shows changed. The view calls
    /// it when the engine's visibility, its node or its document changes; the node when it flips.
    ///
    /// - Parameter newDocument: A document that was never told (a load, a claim).
    func syncLoopVisibility(newDocument: Bool = false) {
        let state = loopVisibility
        guard state.enabled else { return }
        let node = visibilityNode ?? window.map { WindowVisibilitySource.of($0).node }
        if node !== state.node {
            state.node = node
            state.flips = node?.subscribe(owner: "PageWebView.loops") { [weak self] _ in self?.syncLoopVisibility() }
            state.rendering = node?.subscribeRendering(owner: "PageWebView.loops") { [weak self] _ in self?.syncLoopVisibility() }
        }
        if newDocument { state.told = nil }
        guard loaded else { return }
        let shown = engineVisible && (node.map { Self.nodeRunsLoops($0, drawsWhenOccluded: WindowDrawPolicy.drawsWhenOccluded) } ?? false)
        guard state.told != shown else { return }
        state.told = shown
        pushes.run(Self.loopVisibilityScript(shown: shown), whileFrozen: .latest(.loopVisibility))
    }

    /// Whether a page under `node` runs its loops: the node renders, or it is occluded in an
    /// automation launch that draws covered windows (``windowShowsPages(_:drawsWhenOccluded:)``).
    static func nodeRunsLoops(_ node: VisibilityNode, drawsWhenOccluded: Bool) -> Bool {
        node.wantsFrames || windowShowsPages(node.effective, drawsWhenOccluded: drawsWhenOccluded)
    }
}
