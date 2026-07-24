internal import SwiftUI
internal import CmuxSubrouter

/// The uniform trailing usage summary for an account row: a brand-gradient
/// mini gauge plus one short text. Comfortable accounts show the used
/// percentage; exhausted accounts show the constraining window's reset
/// countdown instead — when the account comes back is the useful fact, and
/// the full gauge already says "used up" (no chip, no alarm hue).
struct SubrouterUsageSummaryView: View {
    let account: SubrouterAccountUsageStatus

    var body: some View {
        if let window = account.constrainingWindow {
            let percent = window.clampedUsedPercent
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(SubrouterPalette.usageFill(for: percent))
                    .frame(width: max(2, 44 * percent / 100))
            }
            .frame(width: 44, height: 4)
            .accessibilityHidden(true)
            Text(trailingText(window: window, percent: percent))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(SubrouterPalette.usageAccent(for: percent))
                .help(account.quotaAssessment.detailText ?? "")
        }
    }

    private func trailingText(window: SubrouterUsageWindow, percent: Double) -> String {
        if account.quotaAssessment != .ok, let reset = window.shortResetText {
            return reset
        }
        return String(
            localized: "subrouter.usage.percentUsed",
            defaultValue: "\(Int(percent.rounded()))%"
        )
    }
}
