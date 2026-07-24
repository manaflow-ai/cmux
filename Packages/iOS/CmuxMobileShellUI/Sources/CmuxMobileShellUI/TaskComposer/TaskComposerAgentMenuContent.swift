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
            let models = MobileTaskAgentModelCatalog.models(forCommand: template.command)
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
                        actions.selectTemplate(template.id)
                        actions.selectModel(nil)
                    } label: {
                        Text(L10n.string(
                            "mobile.taskComposer.model.default",
                            defaultValue: "Default"
                        ))
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
                            actions.selectTemplate(template.id)
                            actions.selectModel(model.id)
                        } label: {
                            Text(verbatim: model.displayName)
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
}
#endif
