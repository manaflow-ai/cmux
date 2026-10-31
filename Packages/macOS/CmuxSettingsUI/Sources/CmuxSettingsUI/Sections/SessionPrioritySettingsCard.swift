import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Settings card for `automation.sessionPriority`: ranks Claude sessions by
/// sidebar order and applies an effort/model matrix per tier and difficulty.
/// Off by default. The matrix itself is edited in cmux.json.
@MainActor
struct SessionPrioritySettingsCard: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var urgentCount: DefaultsValueModel<Int>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.sessionPriority))
        _urgentCount = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.sessionPriorityUrgentCount))
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.sessionPriority.enabled"),
                String(
                    localized: "settings.automation.sessionPriority",
                    defaultValue: "Prioritize Claude Sessions by Sidebar Order",
                    bundle: .module
                ),
                subtitle: String(
                    localized: "settings.automation.sessionPriority.subtitle",
                    defaultValue: "cmux restarts idle Claude terminals to change their effort, more for workspaces higher in the sidebar and less further down, and resumes each conversation. It also rates each task's difficulty by sending short conversation excerpts to a small Claude model on your account.",
                    bundle: .module
                )
            ) {
                Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsSessionPriorityToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("automation.sessionPriority.urgentCount"),
                String(
                    localized: "settings.automation.sessionPriority.urgentCount",
                    defaultValue: "Urgent workspaces",
                    bundle: .module
                ),
                subtitle: String(
                    localized: "settings.automation.sessionPriority.urgentCount.subtitle",
                    defaultValue: "How many workspaces at the top of the sidebar count as urgent.",
                    bundle: .module
                ),
                controlWidth: 196
            ) {
                Stepper(
                    value: Binding(get: { urgentCount.current }, set: { urgentCount.set($0) }),
                    in: 0...20
                ) {
                    Text(verbatim: "\(urgentCount.current)")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsSessionPriorityUrgentCountStepper")
                .accessibilityLabel(
                    String(
                        localized: "settings.automation.sessionPriority.urgentCount",
                        defaultValue: "Urgent workspaces",
                        bundle: .module
                    )
                )
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("automation.sessionPriority.matrix"),
                String(
                    localized: "settings.automation.sessionPriority.matrix.hint",
                    defaultValue: "Effort and model per tier and difficulty are set in cmux.json: automation.sessionPriority.matrix",
                    bundle: .module
                )
            ) {
                EmptyView()
            }
        }
        .task {
            startSettingsObservation([enabled, urgentCount])
        }
    }
}
