#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// A transparent UIKit menu button placed over the SwiftUI model-pill label.
///
/// Its uncached deferred element takes one catalog snapshot when UIKit opens
/// the menu. Later discovery updates feed the next opening without replacing
/// the menu currently under the user's finger.
struct TaskComposerModelMenuContent: UIViewRepresentable {
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let selectedModelName: String
    let isEnabled: Bool
    let selectModel: (MobileTaskAgentModel?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = true
        update(button, coordinator: context.coordinator)
        // Install this once. Replacing UIButton.menu from updateUIView while
        // it is presented is what makes UIKit discard the visible choices.
        button.menu = context.coordinator.menu
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: UIButton, coordinator: Coordinator) {
        coordinator.models = models
        coordinator.selectedModelID = selectedModelID
        coordinator.selectModel = selectModel

        button.isEnabled = isEnabled
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityIdentifier = "MobileTaskComposerModelPill"
        button.accessibilityLabel = L10n.string(
            "mobile.taskComposer.model",
            defaultValue: "Model"
        )
        button.accessibilityValue = selectedModelName
        button.accessibilityHint = L10n.string(
            "mobile.taskComposer.model.accessibilityHint",
            defaultValue: "Chooses the model this agent runs with."
        )
    }

    @MainActor
    final class Coordinator {
        var models: [MobileTaskAgentModel] = []
        var selectedModelID: String?
        var selectModel: (MobileTaskAgentModel?) -> Void = { _ in }

        lazy var menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else {
                    completion([])
                    return
                }

                // Copy every presentation-owned value before building actions.
                // These UIActions then remain unchanged until this menu closes.
                let models = self.models
                let selectedModelID = self.selectedModelID
                var actions: [UIMenuElement] = [
                    UIAction(
                        title: L10n.string(
                            "mobile.taskComposer.model.default",
                            defaultValue: "Default"
                        ),
                        state: selectedModelID == nil ? .on : .off
                    ) { [weak self] _ in
                        self?.selectModel(nil)
                    },
                ]
                actions.append(contentsOf: models.map { model in
                    UIAction(
                        title: model.displayName,
                        state: model.id == selectedModelID ? .on : .off
                    ) { [weak self] _ in
                        // Capture the concrete model from this presentation,
                        // not whatever the live catalog contains after refresh.
                        self?.selectModel(model)
                    }
                })
                completion([
                    UIMenu(options: .displayInline, children: actions),
                ])
            },
        ])
    }
}
#endif
