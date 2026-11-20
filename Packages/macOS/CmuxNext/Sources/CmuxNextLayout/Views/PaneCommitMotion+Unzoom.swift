import AppKit
import CmuxNextDesign

/// What an unzoom's move puts on its screen: the pane that had the screen closes to its place over the panes that
/// come back, with its last frame under its moving clip.
extension PaneCommitMotion {
    /// The identifier of the view that shows an unzoom's last frame.
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
            let view = PaneLastFrameView(last.frame, frame: last.rect)
            change.host.addSubview(view)
            view.layer?.zPosition = 1
            lastFrame = view
        }
        for host in others {
            guard let ring = host.chrome.layer, ring.opacity > 0 else { continue }
            add("opacity", from: NSNumber(value: -ring.opacity), to: NSNumber(value: Float(0)), on: ring, token)
        }
    }

    /// Takes an unzoom's last frame away: the motion ends, or a second act shows another layout. The content's live
    /// picture shows again in the same commit.
    func dropLastFrame() {
        (lastFrame as? PaneLastFrameView)?.uncover()
        lastFrame?.removeFromSuperview()
        lastFrame = nil
    }

    /// The pane that an unzoom put above the others gets its `zPosition` back.
    func lower() {
        if let raised { raised.host.layer?.zPosition = raised.z }
        raised = nil
    }
}

/// Shows a pane's last frame as it is: AppKit never draws over it, and it takes no click.
///
/// The content can go on showing a live picture under this one, at its new size (`PaneCommitMotionLastFrame.live`: a
/// terminal's surface). A window that shows through its panes would show both, one over the other. So this view
/// covers that layer while it is in a window: the layer's opacity is 0, not its `isHidden`, so the content draws on.
/// The layer gets the opacity that it had when this view goes: the motion takes it away (``uncover()``), or another
/// hand takes it or a view above it out of its window. The view owns the cover, so no way that takes the last frame
/// out of its window leaves the live picture clear. A window that closes with this view still in it keeps the layer
/// clear: a closed window shows nothing, and the app's close takes the layout out of its window. Neither write has
/// an animation: a fade of the live picture under the last frame would show both again.
private final class PaneLastFrameView: NSView {
    private let picture: Any
    /// The layer that shows the content's live picture under this view; nil: the content has none.
    private weak var live: CALayer?
    /// The opacity that `live` had before this view covered it; nil: this view does not cover it now.
    private var covered: Float?

    // The layer shows the picture as it is.
    nonisolated override var wantsUpdateLayer: Bool { true }

    init(_ last: PaneCommitMotionLastFrame, frame: CGRect) {
        picture = last.contents
        live = last.live
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { uncover() } else { cover() }
    }

    /// The live picture goes clear under this view, one time, with no animation.
    private func cover() {
        guard covered == nil, let live else { return }
        covered = live.opacity
        Self.write(0, to: live)
    }

    /// The live picture shows again, with no animation: its layer has the opacity that it had before the cover. A
    /// layer that is not clear any more keeps what it has: another hand gave it an opacity under this view, and that
    /// one is the newer. Later calls do nothing.
    func uncover() {
        guard let was = covered else { return }
        covered = nil
        guard let live, live.opacity == 0 else { return }
        Self.write(was, to: live)
    }

    private static func write(_ opacity: Float, to layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
    }
}
