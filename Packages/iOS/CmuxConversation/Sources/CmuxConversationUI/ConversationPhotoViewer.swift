#if canImport(UIKit)
import UIKit

/// Messages' full-screen photo viewer: the photo aspect-fits on black with a
/// light status bar, zooms out of its bubble (UIKit's zoom transition, which
/// also supplies the interactive swipe-down dismiss), pinches and
/// double-taps to zoom, and a tap toggles the chrome.
final class ConversationPhotoViewerController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private var chromeHidden = false

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { chromeHidden }

    /// The photo's on-screen frame, the zoom transition's destination.
    var photoView: UIView { imageView }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "conversation.photoViewer"
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module)
        scrollView.addSubview(imageView)

        let symbols = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: symbols), for: .normal)
        closeButton.accessibilityLabel = String(localized: "conversation.photoViewer.close", defaultValue: "Close", bundle: .module)
        closeButton.accessibilityIdentifier = "conversation.photoViewer.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        shareButton.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: symbols), for: .normal)
        shareButton.accessibilityLabel = String(localized: "conversation.photoViewer.share", defaultValue: "Share", bundle: .module)
        shareButton.accessibilityIdentifier = "conversation.photoViewer.share"
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .touchUpInside)
        for button in [closeButton, shareButton] {
            button.tintColor = .white
            if #available(iOS 26.0, *) {
                button.configuration = .glass()
                button.configuration?.image = button.image(for: .normal)
                button.configuration?.baseForegroundColor = .white
            }
            view.addSubview(button)
        }

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        if scrollView.zoomScale == 1 {
            imageView.frame = fittedFrame(in: view.bounds)
            scrollView.contentSize = view.bounds.size
        }
        let safe = view.safeAreaInsets
        closeButton.frame = CGRect(x: 16, y: safe.top + 4, width: 44, height: 44)
        shareButton.frame = CGRect(x: view.bounds.width - 60, y: safe.top + 4, width: 44, height: 44)
    }

    private func fittedFrame(in bounds: CGRect) -> CGRect {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep a zoomed-out photo centered.
        let content = imageView.frame.size
        let insetX = max(0, (scrollView.bounds.width - content.width) / 2)
        let insetY = max(0, (scrollView.bounds.height - content.height) / 2)
        imageView.frame.origin = CGPoint(x: insetX, y: insetY)
        scrollView.contentSize = CGSize(width: max(content.width, scrollView.bounds.width), height: max(content.height, scrollView.bounds.height))
    }

    /// Swipe-down dismissal only starts while the photo is not zoomed in.
    var allowsInteractiveDismiss: Bool { scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 }

    @objc private func tapped() {
        chromeHidden.toggle()
        UIView.animate(withDuration: 0.2) {
            self.closeButton.alpha = self.chromeHidden ? 0 : 1
            self.shareButton.alpha = self.chromeHidden ? 0 : 1
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = tap.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    private func share() {
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }
}
#endif
