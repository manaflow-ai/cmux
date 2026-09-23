#if os(iOS)
import SwiftUI
import UIKit

/// A native bar owns all horizontal layout. SwiftUI supplies the existing
/// actions and menus, but never assigns a width to the navigation title.
struct WorkspaceNavigationBar: UIViewControllerRepresentable {
    struct Item {
        enum ID: Hashable {
            case sidebar, back, alternateScreen, changes, terminals
        }

        let id: ID
        let content: AnyView
    }

    let title: AnyView
    let leadingItems: [Item]
    let trailingItems: [Item]

    func makeUIViewController(context: Context) -> WorkspaceNavigationBarController {
        WorkspaceNavigationBarController()
    }

    func updateUIViewController(_ controller: WorkspaceNavigationBarController, context: Context) {
        controller.update(
            title: title,
            leadingItems: leadingItems,
            trailingItems: trailingItems,
            environment: context.environment
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: WorkspaceNavigationBarController,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiViewController.bar.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}

#endif
