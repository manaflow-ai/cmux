#if os(iOS) && DEBUG
import CmuxMobileSupport
import SwiftUI

struct MobileSettingsDeveloperSections: View {
    let whatsNewPages: [MobileWhatsNewPage]
    let whatsNewHosts: Set<String>
    @Binding var toastDemoDelaySeconds: Int
    @Binding var unreadIndicatorLeftShift: Double
    @Binding var forceRebuildKeyboardDock: Bool
    @Binding var taskComposerFullLiquidGlass: Bool
    let showToastGallery: () -> Void
    let runToastDemo: () -> Void

    var body: some View {
        Section(L10n.string("mobile.settings.developer", defaultValue: "Developer")) {
            NavigationLink {
                MobileWhatsNewDebugView(pages: whatsNewPages, allowedWebHosts: whatsNewHosts)
            } label: {
                Label(
                    L10n.string("mobile.whatsNew.debug.title", defaultValue: "Replay What's New"),
                    systemImage: "rectangle.stack"
                )
            }
            .accessibilityIdentifier("MobileSettingsReplayWhatsNew")
            Button {
                showToastGallery()
            } label: {
                Label(
                    L10n.string("mobile.settings.toastGallery", defaultValue: "Toast Gallery"),
                    systemImage: "rectangle.portrait.topthird.inset.filled"
                )
            }
            .accessibilityIdentifier("MobileSettingsToastGallery")
            Button {
                runToastDemo()
            } label: {
                Label(
                    L10n.string("mobile.settings.toastDemo", defaultValue: "Run Toast Demo"),
                    systemImage: "play.rectangle"
                )
            }
            .accessibilityIdentifier("MobileSettingsToastDemo")
            Stepper(value: $toastDemoDelaySeconds, in: 0...30) {
                HStack {
                    Text(L10n.string(
                        "mobile.settings.toastDemoDelay",
                        defaultValue: "Toast Demo Delay"
                    ))
                    Spacer()
                    Text(String.localizedStringWithFormat(
                        L10n.string(
                            "mobile.settings.toastDemoDelayValueFormat",
                            defaultValue: "%d s"
                        ),
                        toastDemoDelaySeconds
                    ))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("MobileSettingsToastDemoDelay")

            debugLayoutSlider(
                title: L10n.string(
                    "mobile.settings.unreadIndicatorLeftness",
                    defaultValue: "Unread Indicator Leftness"
                ),
                value: $unreadIndicatorLeftShift,
                range: MobileDisplaySettings.unreadIndicatorLeftShiftRange,
                identifier: "MobileSettingsUnreadIndicatorLeftness"
            )

            Toggle(isOn: $forceRebuildKeyboardDock) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "mobile.settings.rebuildKeyboardDock",
                        defaultValue: "Rebuilt Keyboard Pinning"
                    ))
                    Text(L10n.string(
                        "mobile.settings.rebuildKeyboardDockCaption",
                        defaultValue: "Use the rebuilt keyboard path instead of the default (iOS 26 and earlier). Reopen the workspace to apply."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("MobileSettingsRebuildKeyboardDock")
        }

        Section(L10n.string(
            "mobile.settings.cmuxLabs",
            defaultValue: "CMUX Labs"
        )) {
            Toggle(isOn: $taskComposerFullLiquidGlass) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "mobile.settings.taskComposerFullLiquidGlass",
                        defaultValue: "Task Composer Liquid Glass"
                    ))
                    Text(L10n.string(
                        "mobile.settings.taskComposerFullLiquidGlassCaption",
                        defaultValue:
                            "Use Liquid Glass controls and a transparent bar in New Task."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("MobileSettingsTaskComposerFullLiquidGlass")

            NavigationLink {
                TaskComposerShellIconLabView()
            } label: {
                Label(
                    L10n.string(
                        "mobile.settings.shellIconLab",
                        defaultValue: "Shell Icon Lab"
                    ),
                    systemImage: "terminal"
                )
            }
            .accessibilityIdentifier("MobileSettingsShellIconLab")

            NavigationLink {
                UnreadIndicatorLabView()
            } label: {
                Label(
                    L10n.string(
                        "mobile.settings.unreadIndicatorLab",
                        defaultValue: "Unread Indicator Lab"
                    ),
                    systemImage: "circle.badge"
                )
            }
            .accessibilityIdentifier("MobileSettingsUnreadIndicatorLab")
        }
    }

    #if DEBUG
    private func debugLayoutSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(debugPointValue(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
        }
        .accessibilityIdentifier(identifier)
    }

    private func debugPointValue(_ value: Double) -> String {
        String(
            format: L10n.string("mobile.settings.pointsFormat", defaultValue: "%lld pt"),
            Int64(value.rounded())
        )
    }
    #endif
}
#endif
