#if os(iOS)
import SwiftUI
import UIKit

/// Wires iOS 26's `UIScrollEdgeElementContainerInteraction` onto the composer
/// bar without rehosting any SwiftUI content in UIKit.
///
/// The pills stay a plain SwiftUI `ScrollView` (scrolling, menus, and layout
/// keep their proven behavior); a zero-size probe inside the scroll content
/// walks its superviews to find the backing `UIScrollView`, and transparent
/// backgrounds behind the floating button clusters provide the container
/// views the interaction needs. The system then renders its real scroll edge
/// effect (progressive blur + fade) beneath the clusters as pills pass under.
///
/// Fail-soft contract: if the probe never finds a `UIScrollView` (hosting
/// internals changed) or the OS predates the API, nothing attaches and the
/// bar simply underlaps — never a functional regression.
@MainActor
final class TaskComposerScrollEdgeCoordinator {
    private weak var scrollView: UIScrollView?
    private var pendingContainers: [(container: WeakBox, edge: UIRectEdge)] = []

    private struct WeakBox {
        weak var view: UIView?
    }

    func adopt(scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        for entry in pendingContainers {
            guard let view = entry.container.view else { continue }
            attach(container: view, edge: entry.edge, to: scrollView)
        }
    }

    func register(container: UIView, edge: UIRectEdge) {
        pendingContainers.removeAll { $0.container.view == nil || $0.container.view === container }
        pendingContainers.append((WeakBox(view: container), edge))
        if let scrollView {
            attach(container: container, edge: edge, to: scrollView)
        }
    }

    private func attach(container: UIView, edge: UIRectEdge, to scrollView: UIScrollView) {
        guard #available(iOS 26.0, *) else { return }
        let alreadyAttached = container.interactions.contains {
            ($0 as? UIScrollEdgeElementContainerInteraction)?.scrollView === scrollView
        }
        guard !alreadyAttached else { return }
        let interaction = UIScrollEdgeElementContainerInteraction()
        interaction.scrollView = scrollView
        interaction.edge = edge
        container.addInteraction(interaction)
    }
}

/// Zero-size, touch-transparent view placed inside the scroll content; on
/// entering a window it walks its superviews to hand the backing
/// `UIScrollView` to the coordinator.
struct TaskComposerScrollViewProbe: UIViewRepresentable {
    let coordinator: TaskComposerScrollEdgeCoordinator

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.coordinator = coordinator
        view.reportEnclosingScrollView()
    }

    final class ProbeView: UIView {
        var coordinator: TaskComposerScrollEdgeCoordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportEnclosingScrollView()
        }

        func reportEnclosingScrollView() {
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    coordinator?.adopt(scrollView: scrollView)
                    return
                }
                candidate = view.superview
            }
        }
    }
}

/// Touch-transparent view placed behind a floating button cluster; it is the
/// container the scroll edge effect renders beneath.
struct TaskComposerScrollEdgeContainer: UIViewRepresentable {
    let coordinator: TaskComposerScrollEdgeCoordinator
    let edge: UIRectEdge

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        coordinator.register(container: view, edge: edge)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        coordinator.register(container: view, edge: edge)
    }
}
#endif
