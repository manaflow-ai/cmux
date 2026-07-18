import AppKit
import WebKit

/// Keeps the visible design-mode overlays stable while WebKit captures the clean page beneath them.
@MainActor
final class BrowserDesignModeCaptureShield {
    private let imageView: NSImageView
    private let constraints: [NSLayoutConstraint]

    private init(imageView: NSImageView, constraints: [NSLayoutConstraint]) {
        self.imageView = imageView
        self.constraints = constraints
    }

    static func install(image: NSImage, over webView: WKWebView) -> BrowserDesignModeCaptureShield? {
        guard let container = webView.superview else { return nil }

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.imageScaling = .scaleAxesIndependently
        imageView.isEditable = false
        imageView.setAccessibilityElement(false)
        container.addSubview(imageView, positioned: .above, relativeTo: webView)

        let constraints = [
            imageView.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: webView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        return BrowserDesignModeCaptureShield(imageView: imageView, constraints: constraints)
    }

    func remove() {
        NSLayoutConstraint.deactivate(constraints)
        imageView.removeFromSuperview()
    }
}
