#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Keeps the selected agent attached to the prompt while leaving every
/// template and the editor one tap away.
struct TaskComposerAgentMenu: View, Equatable {
    let value: TaskComposerAgentMenuValue
    let actions: TaskComposerAgentMenuActions

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    private var selectedTemplate: MobileTaskTemplate? {
        value.selectedTemplateID.flatMap { id in
            value.templates.first { $0.id == id }
        }
    }

    private var selectedModel: MobileTaskAgentModel? {
        guard value.modelPickerVariant.renderedVariant == .combined,
              let selectedTemplate,
              let selectedModelID = value.selectedModelID else { return nil }
        return MobileTaskAgentModelCatalog.model(
            id: selectedModelID,
            forCommand: selectedTemplate.command
        )
    }

    var body: some View {
        Menu {
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
        } label: {
            HStack(spacing: 10) {
                if let selectedTemplate {
                    TaskTemplateIcon(value: selectedTemplate.icon, size: 18)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.11), in: Circle())
                        .accessibilityHidden(true)

                    Text(title(for: selectedTemplate))
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.055), in: Circle())
                        .accessibilityHidden(true)

                    Text(
                        L10n.string(
                            "mobile.taskComposer.validation.template",
                            defaultValue: "Add an agent before starting a task."
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            // Keep the chrome around the prompt compact while allowing the
            // menu's choices to retain the caller's full Dynamic Type size.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        // Keep the menu reachable when every template has been deleted so the
        // editor remains the recovery path for adding an agent.
        .disabled(value.isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.agent", defaultValue: "Agent"))
        .accessibilityValue(selectedTemplate.map(title(for:)) ?? "")
        .accessibilityHint(TaskComposerSheet.templateAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerAgentMenu")
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

    private func title(for template: MobileTaskTemplate) -> String {
        let baseTitle: String
        if template.isPlainShell {
            baseTitle = L10n.string(
                "mobile.taskComposer.promptTitle.shell",
                defaultValue: "Shell command"
            )
        } else {
            baseTitle = String(
                format: L10n.string(
                    "mobile.taskComposer.promptTitle.agentFormat",
                    defaultValue: "Ask %@"
                ),
                template.name
            )
        }
        guard let selectedModel else { return baseTitle }
        return "\(baseTitle) · \(selectedModel.displayName)"
    }
}
#endif
