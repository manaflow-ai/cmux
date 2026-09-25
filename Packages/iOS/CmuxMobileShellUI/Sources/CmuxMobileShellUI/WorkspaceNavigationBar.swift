#if os(iOS)
import SwiftUI
import UIKit

/// Installs native items on the containing screen's navigation bar without
/// rehosting its content or introducing a second navigation stack.
struct WorkspaceNavigationBar: UIViewControllerRepresentable {
    struct Item {
        enum ID: Hashable {
            case sidebar, back, alternateScreen, changes, terminals
        }

        let id: ID
        enum Content {
            case custom(AnyView)
            case terminals(TerminalPickerMenuValue, TerminalPickerMenuActions)
        }

        let content: Content

        init(id: ID, content: AnyView) {
            self.id = id
            self.content = .custom(content)
        }

        init(terminals value: TerminalPickerMenuValue, actions: TerminalPickerMenuActions) {
            id = .terminals
            content = .terminals(value, actions)
        }
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

    static func dismantleUIViewController(_ controller: WorkspaceNavigationBarController, coordinator: ()) {
        controller.restoreConfiguration()
    }
}
#endif
