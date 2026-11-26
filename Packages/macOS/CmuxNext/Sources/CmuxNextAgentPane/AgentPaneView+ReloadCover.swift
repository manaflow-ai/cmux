public import AppKit
public import CmuxNextPages
import CmuxNextWakeups
import QuartzCore
import WebKit

/// A web update or the live web loop reloads every open chat page in place (``WebBundleServedViews/reload(_:to:)``).
/// The reload showed: the page went blank, the loading state came, the composer drew again, in every chat a window
/// shows. Leo, 2026-11-22: "we need to have far more graceful reloads that appear to just be instantly gracefully
/// transitioned. my composer is ideally untouched as much as possible. likewise with my drafts. ... no shift, no
/// anything, just... ok now it changed. don't bother \"appearing to\" reload the whole thing. we can fake the
/// transition harder."
///
/// So a shown chat reloads under a picture of itself: the picture is taken, laid over the page, the page reloads under
/// it (its draft, attachments, scroll and focus come back by themselves, webSwap.ts), and the picture goes in one step
/// in the turn the new page reports it drew the chat as it stands. A page that reports only a partial frame shows
/// ``settleWithin`` after it; one that reports nothing shows after ``limit`` all the same.
extension AgentPaneView: WebReloadCovering {
    /// The longest the picture stays when the reloaded page never reports a frame (a hung or crashed web process).
    static let reloadCoverLimit: Duration = .seconds(2)
    /// How long the picture waits for the settled chat after the reloaded page drew a partial one.
    static let reloadCoverSettleWithin: Duration = .milliseconds(400)

    /// Nothing to hold: a chat out of sight, one never drawn (its loading state covers it), or one in Chromium,
    /// whose child window draws over any cover in this view.
    public var coversNextReload: Bool {
        reloadCover != nil || (window != nil && !isHiddenOrHasHiddenAncestor && model.hasPainted && !pageDrawsOverCovers
            && !holdsPageAway && !drawsUnseenForHold && pageContent.frame.width >= 1 && pageContent.frame.height >= 1)
    }

    public func reloadUnderCover(_ reload: @escaping @MainActor () -> Void) {
        guard coversNextReload else { return reload() }
        // A second update while the first one's picture is up: the picture stays, its bound starts again.
        if let cover = reloadCover {
            cover.limit.schedule(after: Self.reloadCoverLimit) { @MainActor [weak self] in self?.dropReloadCover() }
            return reload()
        }
        // WebKit's picture of what it shows now (a Chromium chat left above); the reply comes on the main thread.
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, let image, window != nil, !isHiddenOrHasHiddenAncestor, reloadCover == nil else { return reload() }
            showReloadCover(image)
            reload()
        }
    }

    private func showReloadCover(_ image: NSImage) {
        let cover = AgentPaneReloadCover(image: image, frame: pageContent.frame,
                                         scale: window?.backingScaleFactor ?? 2)
        reloadCover = cover
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        addSubview(cover, positioned: .above, relativeTo: pageContent)
        CATransaction.commit()
        cover.limit.schedule(after: Self.reloadCoverLimit) { @MainActor [weak self] in self?.dropReloadCover() }
        model.reloadPaintWaiters.append { [weak self, weak cover] settled in
            guard let self, let cover, reloadCover === cover else { return }
            if settled {
                // The report comes after the page's frame; the picture goes with the pane's next frame.
                redraw.afterNextFrame { [weak self] in self?.dropReloadCover() }
            } else if !cover.sawPartialFrame {
                cover.sawPartialFrame = true
                cover.settle.schedule(after: Self.reloadCoverSettleWithin) { @MainActor [weak self] in self?.dropReloadCover() }
            }
        }
    }

    /// Takes the picture away in one step, showing the reloaded page under it.
    func dropReloadCover() {
        guard let cover = reloadCover else { return }
        reloadCover = nil
        model.reloadPaintWaiters.removeAll()
        cover.limit.cancel()
        cover.settle.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.removeFromSuperview()
        CATransaction.commit()
    }
}

/// The chat's picture held over its page while the page reloads (``AgentPaneView/reloadUnderCover(_:)``). It takes no
/// clicks and says nothing to accessibility: the page under it is the chat.
final class AgentPaneReloadCover: NSView {
    /// Ends the hold when the reloaded page never reports a frame.
    let limit = DemandTimer(owner: "agentPane.reloadCover.limit")
    /// Ends the hold a short while after a partial frame, when the settled one does not come.
    let settle = DemandTimer(owner: "agentPane.reloadCover.settle")
    var sawPartialFrame = false

    init(image: NSImage, frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsScale = scale
        layer?.contents = image.layerContents(forContentsScale: scale)
        layer?.contentsGravity = .resize
        autoresizingMask = [.width, .height] // follows the pane through a resize during the hold
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
