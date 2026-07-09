public import AppKit

/// Flipped document view that centers and sizes the file-preview image inside the scroll view.
///
/// Owns the ``FilePreviewMagnifyingImageView`` and lays it out centered within its own bounds at
/// ``scaledImageSize``. Forwards the current ``rotationDegrees`` and the pinch/smart-magnify/rotate
/// gesture callbacks down to the image view, so the owning container installs a single set of
/// handlers regardless of whether the gesture lands on the document or the image.
public final class FilePreviewImageDocumentView: NSView {
    /// The image view this document view centers and scales.
    public let imageView = FilePreviewMagnifyingImageView()
    /// The target on-screen size of the image, used to position it centered within the bounds.
    public var scaledImageSize = CGSize(width: 1, height: 1)
    /// Clockwise rotation in degrees, forwarded to the image view.
    public var rotationDegrees = 0 {
        didSet {
            imageView.rotationDegrees = rotationDegrees
        }
    }
    /// Invoked on a pinch-magnify gesture; forwarded to the image view.
    public var onMagnify: ((NSEvent) -> Void)? {
        didSet {
            imageView.onMagnify = onMagnify
        }
    }
    /// Invoked on a double-tap smart-magnify gesture; forwarded to the image view.
    public var onSmartMagnify: ((NSEvent) -> Void)? {
        didSet {
            imageView.onSmartMagnify = onSmartMagnify
        }
    }
    /// Invoked on a two-finger rotate gesture; forwarded to the image view.
    public var onRotate: ((NSEvent) -> Void)? {
        didSet {
            imageView.onRotate = onRotate
        }
    }

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
    }

    public required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        imageView.frame = CGRect(
            x: max(0, (bounds.width - scaledImageSize.width) * 0.5),
            y: max(0, (bounds.height - scaledImageSize.height) * 0.5),
            width: scaledImageSize.width,
            height: scaledImageSize.height
        )
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
}
