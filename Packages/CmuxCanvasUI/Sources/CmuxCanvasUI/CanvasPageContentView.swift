import AppKit
import CmuxCanvas

/// The concrete AppKit view used for one native Pages surface.
@MainActor
final class CanvasPageContentView: NSView {
    private(set) var paneView: CanvasPaneView?

    private static let horizontalInset: CGFloat = 14
    private static let verticalInset: CGFloat = 12

    override var isFlipped: Bool { true }

    func configure(
        paneID: CanvasPaneID,
        paneBackground: NSColor,
        delegate: (any CanvasPaneViewDelegate)?
    ) -> CanvasPaneView {
        let view: CanvasPaneView
        if let existing = paneView, existing.paneID == paneID {
            view = existing
        } else {
            paneView?.removeFromSuperview()
            let created = CanvasPaneView(paneID: paneID)
            created.autoresizingMask = [.width, .height]
            addSubview(created)
            paneView = created
            view = created
        }
        view.delegate = delegate
        view.allowsResize = false
        view.allowsTitleBarDrag = false
        view.paneBackground = paneBackground
        needsLayout = true
        return view
    }

    func clear() {
        paneView?.removeFromSuperview()
        paneView = nil
    }

    override func layout() {
        super.layout()
        guard let paneView else { return }
        let insetX = min(Self.horizontalInset, bounds.width / 4)
        let insetY = min(Self.verticalInset, bounds.height / 4)
        paneView.frame = bounds.insetBy(dx: insetX, dy: insetY)
    }
}
