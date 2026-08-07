#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Selects the agent command while keeping template management visually secondary.
struct TaskComposerTemplatePicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let isDisabled: Bool
    let selectTemplate: (MobileTaskTemplate) -> Void
    let editTemplates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("mobile.taskComposer.agent", defaultValue: "Agent"))
                    .font(.headline)
                    .accessibilityIdentifier("MobileTaskComposerRoute")
                Spacer()
                Button(action: editTemplates) {
                    Label(
                        L10n.string("mobile.common.edit", defaultValue: "Edit"),
                        systemImage: "slider.horizontal.3"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 46)
                .contentShape(Rectangle())
                .foregroundStyle(Color.accentColor)
                .disabled(isDisabled)
                .accessibilityIdentifier("MobileTaskComposerEditTemplatesButton")
            }

            if templates.isEmpty {
                Label(
                    L10n.string(
                        "mobile.taskComposer.validation.template",
                        defaultValue: "Add an agent before starting a task."
                    ),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(templates) { template in
                            TaskComposerTemplateOption(
                                template: template,
                                isSelected: template.id == selectedTemplateID,
                                isDisabled: isDisabled,
                                action: { selectTemplate(template) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .contentMargins(.horizontal, 1, for: .scrollContent)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 64 : 52)
            }
        }
    }
}
#endif
