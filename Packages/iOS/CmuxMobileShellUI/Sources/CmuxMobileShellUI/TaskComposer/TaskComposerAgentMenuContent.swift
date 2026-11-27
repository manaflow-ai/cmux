#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Agent choices shown by the composer's provider pill.
struct TaskComposerAgentMenuContent: View {
    let value: TaskComposerAgentMenuValue
    let actions: TaskComposerAgentMenuActions

    var body: some View {
        if !value.templates.isEmpty {
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
}
#endif
