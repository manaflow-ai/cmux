import AppKit

extension CanvasRootView {
    private static let minimapOverlaySize = CGSize(width: 168, height: 112)
    private static let minimapOverlayInset: CGFloat = 14
    private static let minimapOverlayMinimumSize = CGSize(width: 96, height: 64)

    @discardableResult
    func syncMinimapOverlayHost() -> Bool {
        let container = window?.contentView?.superview ?? window?.contentView ?? self
        if minimapView.superview !== container {
            minimapView.removeFromSuperview()
            minimapView.translatesAutoresizingMaskIntoConstraints = true
            minimapView.autoresizingMask = []
            container.addSubview(minimapView, positioned: .above, relativeTo: nil)
        } else if container.subviews.last !== minimapView {
            container.addSubview(minimapView, positioned: .above, relativeTo: nil)
        }
        return positionMinimapOverlay(in: container)
    }

    func detachMinimapOverlay() {
        minimapView.removeFromSuperview()
    }

    @discardableResult
    private func positionMinimapOverlay(in container: NSView) -> Bool {
        let rootRect = container.convert(bounds, from: self)
        guard let frame = Self.minimapOverlayFrame(
            rootRect: rootRect,
            containerIsFlipped: container.isFlipped
        ) else {
            minimapView.frame = .zero
            return false
        }
        minimapView.frame = frame
        return true
    }

    static func minimapOverlayFrame(rootRect: CGRect, containerIsFlipped: Bool) -> CGRect? {
        let size = Self.minimapOverlaySize
        let inset = Self.minimapOverlayInset
        let maxWidth = rootRect.width - inset * 2
        let maxHeight = rootRect.height - inset * 2
        guard maxWidth >= Self.minimapOverlayMinimumSize.width,
              maxHeight >= Self.minimapOverlayMinimumSize.height else {
            return nil
        }

        let resolvedSize = CGSize(
            width: min(size.width, maxWidth),
            height: min(size.height, maxHeight)
        )
        let x = rootRect.maxX - inset - resolvedSize.width
        let y = containerIsFlipped
            ? rootRect.maxY - inset - resolvedSize.height
            : rootRect.minY + inset
        return CGRect(
            x: x,
            y: y,
            width: resolvedSize.width,
            height: resolvedSize.height
        ).integral
    }
}
