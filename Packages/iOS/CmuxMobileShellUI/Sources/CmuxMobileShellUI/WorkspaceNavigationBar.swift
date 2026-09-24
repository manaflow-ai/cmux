#if os(iOS)
import SwiftUI
import UIKit

/// A UIKit navigation controller owns the detail content's navigation chrome
/// and safe areas. SwiftUI supplies the existing content, actions, and menus.
struct WorkspaceNavigationBar: UIViewControllerRepresentable {
    struct Item {
        enum ID: Hashable {
            case sidebar, back, alternateScreen, changes, terminals
        }

        let id: ID
        let content: AnyView
    }

    let title: AnyView
    let content: AnyView
    let backgroundColor: UIColor
    let scrollEdgeGlass: Bool
    let leadingItems: [Item]
    let trailingItems: [Item]

    func makeUIViewController(context: Context) -> WorkspaceNavigationBarController {
        WorkspaceNavigationBarController()
    }

    func updateUIViewController(_ controller: WorkspaceNavigationBarController, context: Context) {
        controller.update(
            title: title,
            content: content,
            backgroundColor: backgroundColor,
            scrollEdgeGlass: scrollEdgeGlass,
            leadingItems: leadingItems,
            trailingItems: trailingItems,
            environment: context.environment
        )
    }

}

#endif
