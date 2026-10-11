import CmuxFoundation
import CmuxSettings
import Foundation
import SwiftUI

/// Browser Memory Saver rows in Settings > Browser: the on/off toggle, how
/// hidden tabs are picked (memory budget or timer), the hidden tab memory
/// budget, the delay before a hidden tab may be freed, and whether a freed
/// tab restores on its own when shown.
@MainActor
struct BrowserMemorySaverSettingsRows: View {
    let controlWidth: CGFloat

    @LiveSetting(\.browser.discardHiddenWebViews) private var enabled
    @LiveSetting(\.browser.hiddenWebViewDiscardMode) private var mode
    @LiveSetting(\.browser.hiddenWebViewMemoryBudgetMB) private var memoryBudgetMB
    @LiveSetting(\.browser.hiddenWebViewDiscardDelaySeconds) private var delay
    @LiveSetting(\.browser.autoRestoreUnloadedPages) private var autoRestore

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("browser.discardHiddenWebViews"),
            String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"),
            subtitle: String(localized: "settings.browser.hiddenWebViewDiscard.subtitle", defaultValue: "Frees page memory from hidden browser tabs. Scroll position, form input, and history come back when a tab is shown again.")
        ) {
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"))
                .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardToggle")
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("browser.hiddenWebViewDiscardMode"),
            String(localized: "settings.browser.hiddenWebViewDiscardMode", defaultValue: "Memory Saver Mode"),
            subtitle: String(localized: "settings.browser.hiddenWebViewDiscardMode.subtitle", defaultValue: "Memory Budget frees the tabs hidden longest once hidden tabs use more than the budget. Timer frees every tab hidden longer than the delay."),
            controlWidth: controlWidth
        ) {
            Picker("", selection: $mode) {
                ForEach(BrowserHiddenWebViewDiscardMode.allCases, id: \.self) { mode in
                    Text(Self.displayName(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!enabled)
            .accessibilityLabel(String(localized: "settings.browser.hiddenWebViewDiscardMode", defaultValue: "Memory Saver Mode"))
            .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardModePicker")
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("browser.hiddenWebViewMemoryBudgetMB"),
            String(localized: "settings.browser.hiddenWebViewMemoryBudget", defaultValue: "Hidden Tab Memory Budget"),
            subtitle: String(localized: "settings.browser.hiddenWebViewMemoryBudget.subtitle", defaultValue: "How much memory hidden browser tabs may use before cmux frees the ones hidden longest."),
            controlWidth: controlWidth
        ) {
            HStack(spacing: 8) {
                Text(Self.formatMemoryBudget(memoryBudgetMB))
                    .cmuxFont(.body, design: .monospaced)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                Stepper("", value: $memoryBudgetMB, in: 256...65_536, step: 256)
                    .labelsHidden()
            }
            .disabled(!enabled || mode != .memoryBudget)
            .accessibilityLabel(String(localized: "settings.browser.hiddenWebViewMemoryBudget", defaultValue: "Hidden Tab Memory Budget"))
            .accessibilityIdentifier("SettingsBrowserHiddenWebViewMemoryBudgetStepper")
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("browser.hiddenWebViewDiscardDelaySeconds"),
            String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"),
            subtitle: String(localized: "settings.browser.hiddenWebViewDiscardDelay.subtitle", defaultValue: "How long a browser tab must stay hidden before cmux may free its page memory. Active downloads, popups, developer tools, fullscreen, and loading pages are skipped."),
            controlWidth: controlWidth
        ) {
            HStack(spacing: 8) {
                Text(Self.formatDelay(delay))
                    .cmuxFont(.body, design: .monospaced)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
                Stepper("", value: $delay, in: 0...3_600, step: 30)
                    .labelsHidden()
            }
            .disabled(!enabled)
            .accessibilityLabel(String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"))
            .accessibilityIdentifier("SettingsBrowserHiddenWebViewDiscardDelayStepper")
        }
        SettingsCardDivider()

        SettingsCardRow(
            configurationReview: .json("browser.autoRestoreUnloadedPages"),
            String(localized: "settings.browser.autoRestoreUnloadedPages", defaultValue: "Restore Unloaded Pages Automatically"),
            subtitle: String(localized: "settings.browser.autoRestoreUnloadedPages.subtitle", defaultValue: "Brings back an unloaded page as soon as its tab is shown. When off, the tab shows the page's last snapshot until you click Restore.")
        ) {
            Toggle("", isOn: $autoRestore)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "settings.browser.autoRestoreUnloadedPages", defaultValue: "Restore Unloaded Pages Automatically"))
                .accessibilityIdentifier("SettingsBrowserAutoRestoreUnloadedPagesToggle")
        }
    }

    private static func displayName(_ mode: BrowserHiddenWebViewDiscardMode) -> String {
        switch mode {
        case .memoryBudget:
            String(localized: "settings.browser.hiddenWebViewDiscardMode.memoryBudget", defaultValue: "Memory Budget")
        case .timer:
            String(localized: "settings.browser.hiddenWebViewDiscardMode.timer", defaultValue: "Timer")
        }
    }

    private static func formatMemoryBudget(_ megabytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1024 * 1024, countStyle: .memory)
    }

    /// Formats the delay as `Xm Ys` (or `Ys`) so the stepper readout reads
    /// naturally for delays measured in minutes.
    private static func formatDelay(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 {
            let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.seconds", defaultValue: "%llds")
            return String.localizedStringWithFormat(format, Int64(total))
        }
        if total % 60 == 0 {
            let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.minutes", defaultValue: "%lldm")
            return String.localizedStringWithFormat(format, Int64(total / 60))
        }
        let format = String(localized: "settings.browser.hiddenWebViewDiscardDelay.minutesSeconds", defaultValue: "%lldm %llds")
        return String.localizedStringWithFormat(format, Int64(total / 60), Int64(total % 60))
    }
}
