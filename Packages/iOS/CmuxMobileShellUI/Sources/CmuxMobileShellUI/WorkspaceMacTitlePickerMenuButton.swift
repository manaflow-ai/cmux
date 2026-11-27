#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Keep one native menu installed while SwiftUI updates the toolbar around it.
struct WorkspaceMacTitlePickerMenuButton: UIViewRepresentable {
    let value: WorkspaceMacTitlePickerMenuValue
    let actions: WorkspaceMacTitlePickerActions
    let accessibilityLabel: String
    let accessibilityValue: String

    func makeCoordinator() -> Coordinator {
        Coordinator(value: value, actions: actions)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        // Replacing this while presented makes UIKit refresh the open menu.
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
        button.accessibilityIdentifier = "MobileWorkspaceMacPicker"
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityValue = accessibilityValue
    }

    @MainActor
    final class Coordinator {
        var value: WorkspaceMacTitlePickerMenuValue
        var actions: WorkspaceMacTitlePickerActions

        init(value: WorkspaceMacTitlePickerMenuValue, actions: WorkspaceMacTitlePickerActions) {
            self.value = value
            self.actions = actions
        }

        lazy var menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.makeMenuElements() ?? [])
            },
        ])

        func makeMenuElements() -> [UIMenuElement] {
            // Capture rows and their callbacks together for this opening. Live
            // title, loading, and connection state never reach the menu rows.
            let value = value
            let actions = actions
            var elements: [UIMenuElement] = [action(
                L10n.string("mobile.workspaces.macPicker.allConnections", defaultValue: "All Computers"),
                identifier: "MobileWorkspaceMacPickerAll",
                selected: value.selection == .all
            ) { actions.select(.all) }]

            for machine in value.machines {
                let selection = WorkspaceMacSelection.machine(machine.id)
                let stableID = machine.id.replacingOccurrences(of: "\u{1F}", with: "-")
                elements.append(action(
                    machine.name,
                    subtitle: machine.buildLabel.map { MacAppInstanceDisplayFormatter().localizedBuildLabel($0) },
                    identifier: "MobileWorkspaceMacPickerMachine-\(stableID)",
                    selected: value.selection == selection
                ) { actions.select(selection) })
            }

            if value.canAddDevice {
                elements.append(UIMenu(options: .displayInline, children: [action(
                    L10n.string("mobile.connections.add", defaultValue: "Add Computer"),
                    image: UIImage(systemName: "plus"),
                    identifier: "MobileWorkspaceMacPickerAdd"
                ) { actions.addDevice?() }]))
            }
            return elements
        }

        private func action(
            _ title: String,
            subtitle: String? = nil,
            image: UIImage? = nil,
            identifier: String,
            selected: Bool = false,
            handler: @escaping () -> Void
        ) -> UIAction {
            let action = UIAction(
                title: title,
                subtitle: subtitle,
                image: image,
                identifier: UIAction.Identifier(identifier),
                state: selected ? .on : .off
            ) { _ in handler() }
            action.accessibilityIdentifier = identifier
            return action
        }
    }
}
#endif
