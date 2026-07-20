#if os(iOS)
import SwiftUI
import UIKit

/// An aspect-fit image surface with native pinch, pan, and double-tap zoom.
struct ChatArtifactZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onMinimumZoomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMinimumZoomChanged: onMinimumZoomChanged)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = CGFloat(context.coordinator.policy.minimumScale)
        scrollView.maximumZoomScale = CGFloat(context.coordinator.policy.maximumScale)
        scrollView.zoomScale = scrollView.minimumZoomScale
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView
        context.coordinator.reportMinimumZoomIfNeeded(force: true)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onMinimumZoomChanged = onMinimumZoomChanged
        if context.coordinator.imageView.image !== image {
            context.coordinator.imageView.image = image
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }
        context.coordinator.reportMinimumZoomIfNeeded(force: false)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        let policy = ChatArtifactZoomPolicy()
        weak var scrollView: UIScrollView?
        var onMinimumZoomChanged: (Bool) -> Void
        private var lastReportedMinimumState: Bool?

        init(onMinimumZoomChanged: @escaping (Bool) -> Void) {
            self.onMinimumZoomChanged = onMinimumZoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            reportMinimumZoomIfNeeded(force: false)
        }

        @objc
        func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let targetScale = CGFloat(policy.scaleAfterDoubleTap(
                currentScale: Double(scrollView.zoomScale)
            ))
            if policy.isAtMinimum(Double(scrollView.zoomScale)) {
                let location = recognizer.location(in: imageView)
                let width = scrollView.bounds.width / targetScale
                let height = scrollView.bounds.height / targetScale
                scrollView.zoom(
                    to: CGRect(
                        x: location.x - width / 2,
                        y: location.y - height / 2,
                        width: width,
                        height: height
                    ),
                    animated: true
                )
            } else {
                scrollView.setZoomScale(targetScale, animated: true)
            }
        }

        func reportMinimumZoomIfNeeded(force: Bool) {
            guard let scrollView else { return }
            let swipeOwner = policy.horizontalSwipeOwner(at: Double(scrollView.zoomScale))
            // The page controller's ancestor pan recognizer must own fitted
            // images. A nested UIScrollView pan still wins gesture arbitration
            // even when it has no scrollable content, swallowing the page swipe.
            scrollView.panGestureRecognizer.isEnabled = swipeOwner == .image
            let isAtMinimum = swipeOwner == .pager
            guard force || lastReportedMinimumState != isAtMinimum else { return }
            lastReportedMinimumState = isAtMinimum
            onMinimumZoomChanged(isAtMinimum)
        }
    }
}
#endif
