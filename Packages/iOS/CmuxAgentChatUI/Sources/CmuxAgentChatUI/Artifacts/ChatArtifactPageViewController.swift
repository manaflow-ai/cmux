#if os(iOS)
import SwiftUI
import UIKit

/// Bridges path-stable artifact hosts into UIKit's transactional page controller.
struct ChatArtifactPageViewController: UIViewControllerRepresentable {
    let pages: [ChatArtifactViewerHostedPage]
    @Binding var selectedPath: String
    let isPagingEnabled: Bool

    func makeCoordinator() -> ChatArtifactPageViewControllerCoordinator {
        ChatArtifactPageViewControllerCoordinator()
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        controller.view.backgroundColor = .systemBackground
        controller.view.isOpaque = true
        controller.view.clipsToBounds = true
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.attach(controller)
        context.coordinator.update(
            pages: pages,
            selectedPath: selectedPath,
            selection: $selectedPath,
            isPagingEnabled: isPagingEnabled
        )
        return controller
    }

    func updateUIViewController(
        _ controller: UIPageViewController,
        context: Context
    ) {
        context.coordinator.update(
            pages: pages,
            selectedPath: selectedPath,
            selection: $selectedPath,
            isPagingEnabled: isPagingEnabled
        )
    }
}
#endif
