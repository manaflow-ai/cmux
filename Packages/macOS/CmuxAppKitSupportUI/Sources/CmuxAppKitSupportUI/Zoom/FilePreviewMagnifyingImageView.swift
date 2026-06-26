public import AppKit

/// `NSImageView` subclass for the file-preview image canvas that supports rotation and gestures.
///
/// Forwards pinch-magnify, double-tap smart-magnify, and two-finger rotate gestures to optional
/// callbacks (falling back to `super` when unset), and draws the image rotated by
/// ``rotationDegrees`` about its center, scaled to fit the available bounds. When the rotation is
/// zero it defers entirely to the standard `NSImageView` drawing path.
public final class FilePreviewMagnifyingImageView: NSImageView {
    /// Invoked on a pinch-magnify gesture; falls back to `super` when unset.
    public var onMagnify: ((NSEvent) -> Void)?
    /// Invoked on a double-tap smart-magnify gesture; falls back to `super` when unset.
    public var onSmartMagnify: ((NSEvent) -> Void)?
    /// Invoked on a two-finger rotate gesture; falls back to `super` when unset.
    public var onRotate: ((NSEvent) -> Void)?
    /// Clockwise rotation in degrees applied to the drawn image; triggers a redraw on change.
    public var rotationDegrees = 0 {
        didSet {
            needsDisplay = true
        }
    }

    public override func magnify(with event: NSEvent) {
        if let onMagnify {
            onMagnify(event)
        } else {
            super.magnify(with: event)
        }
    }

    public override func smartMagnify(with event: NSEvent) {
        if let onSmartMagnify {
            onSmartMagnify(event)
        } else {
            super.smartMagnify(with: event)
        }
    }

    public override func rotate(with event: NSEvent) {
        if let onRotate {
            onRotate(event)
        } else {
            super.rotate(with: event)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        guard let image, rotationDegrees != 0 else {
            super.draw(dirtyRect)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: CGFloat(rotationDegrees))
        transform.concat()

        let drawSize = rotatedDrawSize(for: image.size)
        let drawRect = CGRect(
            x: -drawSize.width * 0.5,
            y: -drawSize.height * 0.5,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func rotatedDrawSize(for imageSize: CGSize) -> CGSize {
        let availableSize: CGSize
        if abs(rotationDegrees) % 180 == 90 {
            availableSize = CGSize(width: bounds.height, height: bounds.width)
        } else {
            availableSize = bounds.size
        }
        let scale = min(
            availableSize.width / max(imageSize.width, 1),
            availableSize.height / max(imageSize.height, 1)
        )
        return CGSize(
            width: max(1, imageSize.width * scale),
            height: max(1, imageSize.height * scale)
        )
    }
}
