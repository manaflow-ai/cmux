#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// A transparent deferred UIKit menu over the native effort pill.
struct TaskComposerEffortMenuContent: UIViewRepresentable {
    let efforts: [MobileTaskAgentEffort]
    let selectedEffortID: String?
    let selectedEffortName: String
    let isEnabled: Bool
    let selectEffort: (MobileTaskAgentEffort?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        update(button, coordinator: context.coordinator)
        button.menu = context.coordinator.menu
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: UIButton, coordinator: Coordinator) {
        coordinator.efforts = efforts
        coordinator.selectedEffortID = selectedEffortID
        coordinator.selectEffort = selectEffort

        button.isEnabled = isEnabled
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        if !isEnabled {
            button.accessibilityTraits.insert(.notEnabled)
        }
        button.accessibilityIdentifier = "MobileTaskComposerEffortPill"
        button.accessibilityLabel = L10n.string(
            "mobile.taskComposer.effort",
            defaultValue: "Effort"
        )
        button.accessibilityValue = selectedEffortName
        button.accessibilityHint = L10n.string(
            "mobile.taskComposer.effort.accessibilityHint",
            defaultValue: "Chooses the effort supported by the selected model."
        )
    }

    @MainActor
    final class Coordinator {
        var efforts: [MobileTaskAgentEffort] = []
        var selectedEffortID: String?
        var selectEffort: (MobileTaskAgentEffort?) -> Void = { _ in }

        lazy var menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else {
                    completion([])
                    return
                }
                let efforts = self.efforts
                let selectedEffortID = self.selectedEffortID
                let actions = efforts.map { effort in
                    UIAction(
                        title: effort.displayName,
                        subtitle: effort.description,
                        state: effort.id == selectedEffortID ? .on : .off
                    ) { [weak self] _ in
                        self?.selectEffort(effort)
                    }
                }
                completion([UIMenu(options: .displayInline, children: actions)])
            },
        ])
    }
}
#endif
