public import AppKit

/// `NSImageView` for the file preview that forwards trackpad gestures to
/// closures and rotates its drawn image by `rotationDegrees`.
///
/// Magnify, smart-magnify, and rotate events are handed to the owner via the
/// `on*` closures when set (otherwise the AppKit default runs). When rotated,
/// `draw(_:)` rotates around the view center and rescales the image to fit the
/// rotated bounds so the rotated image stays fully visible.
public final class FilePreviewMagnifyingImageView: NSImageView {
    /// Invoked for a pinch magnify gesture; falls back to AppKit when nil.
    public var onMagnify: ((NSEvent) -> Void)?
    /// Invoked for a smart-magnify (double-tap) gesture; falls back to AppKit when nil.
    public var onSmartMagnify: ((NSEvent) -> Void)?
    /// Invoked for a rotate gesture; falls back to AppKit when nil.
    public var onRotate: ((NSEvent) -> Void)?
    /// The clockwise rotation applied when drawing the image, in degrees.
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
