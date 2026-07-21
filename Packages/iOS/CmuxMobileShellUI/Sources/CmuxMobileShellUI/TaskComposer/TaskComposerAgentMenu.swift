#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Keeps the selected agent attached to the prompt while leaving every
/// template and the editor one tap away.
struct TaskComposerAgentMenu: View {
    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let isDisabled: Bool
    let selectTemplate: (MobileTaskTemplate) -> Void
    let editTemplates: () -> Void

    private var selectedTemplate: MobileTaskTemplate? {
        selectedTemplateID.flatMap { id in
            templates.first { $0.id == id }
        }
    }

    private var templateSelection: Binding<MobileTaskTemplate.ID?> {
        Binding(
            get: { selectedTemplateID },
            set: { id in
                guard let id,
                      let template = templates.first(where: { $0.id == id }) else { return }
                selectTemplate(template)
            }
        )
    }

    var body: some View {
        Menu {
            if !templates.isEmpty {
                Picker(
                    L10n.string("mobile.taskComposer.agent", defaultValue: "Agent"),
                    selection: templateSelection
                ) {
                    ForEach(templates) { template in
                        Text(template.name)
                            .tag(Optional(template.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            Button(action: editTemplates) {
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
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // Keep the chrome around the prompt compact while allowing the
            // menu's choices to retain the caller's full Dynamic Type size.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .buttonStyle(.plain)
        // Keep the menu reachable when every template has been deleted so the
        // editor remains the recovery path for adding an agent.
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.agent", defaultValue: "Agent"))
        .accessibilityValue(selectedTemplate?.name ?? "")
        .accessibilityHint(TaskComposerSheet.templateAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerAgentMenu")
    }

    private func title(for template: MobileTaskTemplate) -> String {
        if template.isPlainShell {
            return L10n.string(
                "mobile.taskComposer.promptTitle.shell",
                defaultValue: "Shell command"
            )
        }
        return String(
            format: L10n.string(
                "mobile.taskComposer.promptTitle.agentFormat",
                defaultValue: "Ask %@"
            ),
            template.name
        )
    }
}
#endif
