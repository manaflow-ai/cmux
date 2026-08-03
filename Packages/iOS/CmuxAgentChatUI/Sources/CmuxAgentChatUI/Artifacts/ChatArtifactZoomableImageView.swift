#if os(iOS)
import UIKit

/// Native aspect-fit image surface with pinch, pan, double-tap zoom, and actions.
@MainActor
final class ChatArtifactZoomableImageNativeView: UIScrollView,
    UIScrollViewDelegate,
    UIContextMenuInteractionDelegate
{
    private let imageView = UIImageView()
    private let policy = ChatArtifactZoomPolicy()
    private var onMinimumZoomChanged: (Bool) -> Void
    private var onAction: (@MainActor (ChatArtifactAction) -> Void)?
    private var lastReportedMinimumState: Bool?

    init(
        image: UIImage,
        onMinimumZoomChanged: @escaping (Bool) -> Void,
        onAction: (@MainActor (ChatArtifactAction) -> Void)?
    ) {
        self.onMinimumZoomChanged = onMinimumZoomChanged
        self.onAction = onAction
        super.init(frame: .zero)

        delegate = self
        minimumZoomScale = CGFloat(policy.minimumScale)
        maximumZoomScale = CGFloat(policy.maximumScale)
        zoomScale = minimumZoomScale
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.addInteraction(UIContextMenuInteraction(delegate: self))
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        reportMinimumZoomIfNeeded(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        image: UIImage,
        onMinimumZoomChanged: @escaping (Bool) -> Void,
        onAction: (@MainActor (ChatArtifactAction) -> Void)?
    ) {
        self.onMinimumZoomChanged = onMinimumZoomChanged
        self.onAction = onAction
        if imageView.image !== image {
            imageView.image = image
            setZoomScale(minimumZoomScale, animated: false)
        }
        reportMinimumZoomIfNeeded(force: false)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        reportMinimumZoomIfNeeded(force: false)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let onAction else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: ChatArtifactActionVisibilityPolicy.imageActions.map { action in
                UIAction(
                    title: action.localizedTitle,
                    image: UIImage(systemName: action.systemImage)
                ) { _ in
                    onAction(action)
                }
            })
        })
    }

    @objc
    private func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let targetScale = CGFloat(policy.scaleAfterDoubleTap(currentScale: Double(zoomScale)))
        if policy.isAtMinimum(Double(zoomScale)) {
            let location = recognizer.location(in: imageView)
            let width = bounds.width / targetScale
            let height = bounds.height / targetScale
            zoom(
                to: CGRect(
                    x: location.x - width / 2,
                    y: location.y - height / 2,
                    width: width,
                    height: height
                ),
                animated: true
            )
        } else {
            setZoomScale(targetScale, animated: true)
        }
    }

    private func reportMinimumZoomIfNeeded(force: Bool) {
        let swipeOwner = policy.horizontalSwipeOwner(at: Double(zoomScale))
        panGestureRecognizer.isEnabled = swipeOwner == .image
        let isAtMinimum = swipeOwner == .pager
        guard force || lastReportedMinimumState != isAtMinimum else { return }
        lastReportedMinimumState = isAtMinimum
        onMinimumZoomChanged(isAtMinimum)
    }
}
#endif
