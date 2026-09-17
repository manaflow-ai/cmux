#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Shared agent choices used by the classic agent row and minimal composer pill.
struct TaskComposerAgentMenuContent: View {
    let value: TaskComposerAgentMenuValue
    let actions: TaskComposerAgentMenuActions

    var body: some View {
        if value.modelPickerVariant.renderedVariant == .combined {
            combinedChoices
        } else if !value.templates.isEmpty {
            Picker(
                L10n.string("mobile.taskComposer.agent", defaultValue: "Agent"),
                selection: Binding(
                    get: { value.selectedTemplateID },
                    set: { id in
                        guard let id,
                              value.templates.contains(where: { $0.id == id }) else { return }
                        actions.selectTemplate(id)
                    }
                )
            ) {
                ForEach(value.templates) { template in
                    Text(template.name)
                        .tag(Optional(template.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Divider()

        Button(action: actions.editTemplates) {
            Label(
                L10n.string(
                    "mobile.taskComposer.agent.edit",
                    defaultValue: "Edit Agents"
                ),
                systemImage: "slider.horizontal.3"
            )
        }
        .accessibilityIdentifier("MobileTaskComposerEditTemplatesButton")
    }

    @ViewBuilder
    private var combinedChoices: some View {
        ForEach(value.templates) { template in
            let models = template.id == value.selectedTemplateID
                ? value.models
                : MobileTaskAgentProvider(command: template.command)?.models ?? []
            if models.isEmpty {
                Button {
                    actions.selectTemplate(template.id)
                } label: {
                    Text(template.name)
                }
                .accessibilityAddTraits(
                    template.id == value.selectedTemplateID ? .isSelected : []
                )
                .accessibilityIdentifier("MobileTaskComposerAgentChoice-\(template.id)")
            } else {
                Menu {
                    Button {
                        actions.selectTemplateAndModel(template.id, nil)
                    } label: {
                        modelChoiceLabel(
                            L10n.string(
                                "mobile.taskComposer.model.default",
                                defaultValue: "Default"
                            ),
                            isSelected: template.id == value.selectedTemplateID
                                && value.selectedModelID == nil
                        )
                    }
                    .accessibilityAddTraits(
                        template.id == value.selectedTemplateID
                            && value.selectedModelID == nil ? .isSelected : []
                    )
                    .accessibilityIdentifier(
                        "MobileTaskComposerAgentModel-\(template.id)-default"
                    )

                    ForEach(models) { model in
                        Button {
                            actions.selectTemplateAndModel(template.id, model.id)
                        } label: {
                            modelChoiceLabel(
                                model.displayName,
                                isSelected: template.id == value.selectedTemplateID
                                    && model.id == value.selectedModelID
                            )
                        }
                        .accessibilityAddTraits(
                            template.id == value.selectedTemplateID
                                && model.id == value.selectedModelID ? .isSelected : []
                        )
                        .accessibilityIdentifier(
                            "MobileTaskComposerAgentModel-\(template.id)-\(model.id)"
                        )
                    }
                } label: {
                    Text(template.name)
                }
                .accessibilityIdentifier("MobileTaskComposerAgentSubmenu-\(template.id)")
            }
        }
    }

    /// A menu row with a visible checkmark on the current choice, mirroring
    /// the native Picker treatment the submenu cannot use (its selection
    /// spans template + model).
    @ViewBuilder
    private func modelChoiceLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(verbatim: title)
        }
    }
}
#endif
