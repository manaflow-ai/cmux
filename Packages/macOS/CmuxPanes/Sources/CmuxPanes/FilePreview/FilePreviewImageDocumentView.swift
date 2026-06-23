public import AppKit

/// Flipped document view that hosts the file preview's
/// `FilePreviewMagnifyingImageView`, centering it at `scaledImageSize` and
/// forwarding gesture closures and `rotationDegrees` down to the image view.
///
/// Used as the `documentView` of `FilePreviewImageScrollView`. It owns the
/// image view, lays it out centered inside its own bounds, and mirrors the
/// gesture/rotation state onto the image view via `didSet`.
public final class FilePreviewImageDocumentView: NSView {
    /// The hosted image view; the only subview, centered by `layout()`.
    public let imageView = FilePreviewMagnifyingImageView()
    /// The size the image is rendered at, used to center the image view.
    public var scaledImageSize = CGSize(width: 1, height: 1)
    /// The clockwise rotation in degrees, forwarded to the image view.
    public var rotationDegrees = 0 {
        didSet {
            imageView.rotationDegrees = rotationDegrees
        }
    }
    /// Forwarded to the image view's `onMagnify`.
    public var onMagnify: ((NSEvent) -> Void)? {
        didSet {
            imageView.onMagnify = onMagnify
        }
    }
    /// Forwarded to the image view's `onSmartMagnify`.
    public var onSmartMagnify: ((NSEvent) -> Void)? {
        didSet {
            imageView.onSmartMagnify = onSmartMagnify
        }
    }
    /// Forwarded to the image view's `onRotate`.
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

    required init?(coder: NSCoder) {
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
