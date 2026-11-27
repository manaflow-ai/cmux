#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

/// UIKit owns the open menu. SwiftUI updates only the inputs for its next opening.
struct TerminalPickerMenuButton: UIViewRepresentable {
    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions

    func makeCoordinator() -> Coordinator {
        Coordinator(value: value, actions: actions)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        // Install once: replacing this while presented resets native menu scroll.
        button.menu = context.coordinator.menu
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        update(button, coordinator: context.coordinator)
    }

    func update(_ button: UIButton, coordinator: Coordinator) {
        coordinator.value = value
        coordinator.actions = actions
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityIdentifier = "MobileTerminalDropdown"
        button.accessibilityLabel = L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")
        button.accessibilityValue = value.selectedName ?? ""
    }

    @MainActor
    final class Coordinator {
        var value: TerminalPickerMenuValue
        var actions: TerminalPickerMenuActions

        init(value: TerminalPickerMenuValue, actions: TerminalPickerMenuActions) {
            self.value = value
            self.actions = actions
        }

        lazy var menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.makeMenuElements() ?? [])
            },
        ])

        /// Copy all displayed data and action targets together for this opening.
        /// No observable store or SwiftUI binding reaches the presented rows.
        func makeMenuElements() -> [UIMenuElement] {
            #if DEBUG
            TerminalPickerMenuDiagnostics().recordPresentation(rowCount: value.rows.count)
            #endif
            return TerminalPickerMenuContent(value: value, actions: actions).makeElements()
        }
    }
}
#endif
