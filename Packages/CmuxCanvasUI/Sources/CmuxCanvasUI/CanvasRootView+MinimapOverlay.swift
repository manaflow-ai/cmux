import AppKit

extension CanvasRootView {
    private static let minimapOverlaySize = CGSize(width: 168, height: 112)
    private static let minimapOverlayInset: CGFloat = 14

    func syncMinimapOverlayHost() {
        guard let window, let container = window.contentView?.superview ?? window.contentView else { return }
        if minimapView.superview !== container {
            minimapView.removeFromSuperview()
            minimapView.translatesAutoresizingMaskIntoConstraints = true
            minimapView.autoresizingMask = []
            container.addSubview(minimapView, positioned: .above, relativeTo: nil)
        } else if container.subviews.last !== minimapView {
            container.addSubview(minimapView, positioned: .above, relativeTo: nil)
        }
        positionMinimapOverlay(in: container)
    }

    func detachMinimapOverlay() {
        minimapView.removeFromSuperview()
    }

    private func positionMinimapOverlay(in container: NSView) {
        let rootRect = container.convert(bounds, from: self)
        let size = Self.minimapOverlaySize
        let inset = Self.minimapOverlayInset
        let y = container.isFlipped ? rootRect.maxY - inset - size.height : rootRect.minY + inset
        minimapView.frame = CGRect(
            x: rootRect.maxX - inset - size.width,
            y: y,
            width: size.width,
            height: size.height
        ).integral
    }
}
