import AppKit
import CmuxNextDesign

/// What an unzoom's move puts on its screen: the pane that had the screen closes to its place over the panes that
/// come back, with its last frame under its moving clip.
extension PaneCommitMotion {
    /// The identifier of the view that shows an unzoom's last frame, and the name of the layer that shows it in a
    /// pane's card.
    static let lastFrameName = "pane.commit.lastFrame"

    /// A pane's last frame, taken before the pane's content heard a new size: the picture, and where it showed in
    /// the pane's host.
    struct Taken {
        let host: PaneHostView
        let frame: PaneCommitMotionLastFrame
        let rect: CGRect
    }

    /// The last frame of `host`'s content as it shows now; nil: the content gives none.
    static func takeLastFrame(of host: PaneHostView) -> Taken? {
        guard let giver = host.content.paneCommitMotionLastFrameGiver, let frame = giver.paneCommitMotionLastFrame else { return nil }
        return Taken(host: host, frame: frame, rect: host.convert(frame.rect, from: giver))
    }

    /// The pane of `change` closes from its screen's size over the panes that came back (`others`), which show at
    /// their places from this frame. Its host goes above each other pane of its screen until the motion's end.
    /// `last` shows over its content where it showed before, at its old size, not scaled, so the pane's top leading
    /// corner keeps its picture and the moving clip cuts it; a content that keeps its own picture has none. The
    /// rings of the others come with the move, so none shows over the pane at the start.
    func closeOver(_ change: Change, last: Taken?, others: [PaneHostView], _ token: MotionSpring) {
        guard let layer = change.host.layer else { return }
        if raised?.host !== change.host {
            lower()
            raised = (host: change.host, z: layer.zPosition)
        }
        layer.zPosition = 1
        if let last, last.host === change.host {
            if change.host.wholeCard, let card = change.host.clipView.layer {
                // The pane's clip is its card: the last frame is in it, so the card cuts it with its corners in each
                // frame. A layer, not a view: a view that leaves the clip ends a hold of the pane's content.
                let shown = CALayer()
                shown.name = Self.lastFrameName
                shown.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
                // The gravity is of a layer whose space goes up, as the view's is; the card's space can go down.
                shown.isGeometryFlipped = card.contentsAreFlipped()
                shown.contentsGravity = last.frame.gravity
                shown.contentsScale = last.frame.scale
                shown.contents = last.frame.contents
                shown.frame = change.host.clipView.convert(last.rect, from: change.host)
                shown.zPosition = 1
                card.addSublayer(shown)
                lastFrameInCard = shown
            } else {
                let view = PaneLastFrameView(last.frame, frame: last.rect)
                change.host.addSubview(view)
                view.layer?.zPosition = 1
                lastFrame = view
            }
        }
        for host in others {
            guard let ring = host.chrome.layer, ring.opacity > 0 else { continue }
            add("opacity", from: NSNumber(value: -ring.opacity), to: NSNumber(value: Float(0)), on: ring, token)
        }
    }

    /// Takes an unzoom's last frame away: the motion ends, or a second act shows another layout.
    func dropLastFrame() {
        lastFrame?.removeFromSuperview()
        lastFrame = nil
        lastFrameInCard?.removeFromSuperlayer()
        lastFrameInCard = nil
    }

    /// The pane that an unzoom put above the others gets its `zPosition` back.
    func lower() {
        if let raised { raised.host.layer?.zPosition = raised.z }
        raised = nil
    }
}

/// Shows a pane's last frame as it is: AppKit never draws over it, and it takes no click.
private final class PaneLastFrameView: NSView {
    private let picture: Any

    // The layer shows the picture as it is.
    nonisolated override var wantsUpdateLayer: Bool { true }

    init(_ last: PaneCommitMotionLastFrame, frame: CGRect) {
        picture = last.contents
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier(PaneCommitMotion.lastFrameName)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.contentsGravity = last.gravity
        layer?.contentsScale = last.scale
        layer?.contents = last.contents
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateLayer() {
        layer?.contents = picture
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
