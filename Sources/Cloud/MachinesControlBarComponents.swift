import AppKit
import SwiftUI

/// "2 of 3" plan meter. Turns into the upgrade hint when a free plan hits its
/// machine ceiling — the moment of intent, and the only place we mention it.
struct MachinePlanMeter: View {
    let plan: MachinePlanSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Text(meterText)
                .cmuxFont(size: 11, monospacedDigit: true)
                .foregroundColor(plan.isAtLimit ? Color.orange : .secondary)
            if plan.isAtLimit && !plan.isPaidPlan {
                Text(String(localized: "machines.meter.upgrade", defaultValue: "Upgrade for more"))
                    .cmuxFont(size: 11)
                    .foregroundColor(.orange)
            }
        }
        .help(meterHelp)
        .accessibilityElement(children: .combine)
    }

    private var meterText: String { plan.countLabel }

    private var meterHelp: String {
        if plan.isAtLimit && !plan.isPaidPlan, let maxActiveVms = plan.maxActiveVms {
            if plan.isSingleMachinePlan {
                return String(
                    localized: "machines.meter.help.atLimit.single",
                    defaultValue: "Your plan includes 1 machine. Upgrade to create more."
                )
            }
            return String(
                localized: "machines.meter.help.atLimit",
                defaultValue: "Your plan includes %d machines. Upgrade to create more."
            ).replacingOccurrences(of: "%d", with: String(maxActiveVms))
        }
        return String(
            localized: "machines.meter.help",
            defaultValue: "Machines on your plan. Sleeping machines cost nothing."
        )
    }
}

/// One line under the header on free plans: how long the fleet stays
/// reachable, counting down to the earliest machine's expiry, and the way out
/// (the whole line is the upgrade affordance — the same Pro flow the ＋ button
/// opens at the machine ceiling).
struct MachinesFreeAccessBanner: View {
    let text: String
    let isExpired: Bool
    let windowDays: Int
    let backgroundColor: NSColor
    @State private var isHovered = false

    var body: some View {
        Button {
            ProUpgradePresenter.present(source: .machinesPanelTrialBanner)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpired ? "lock.fill" : "clock")
                    .font(.system(size: 10, weight: .semibold))
                Text(text)
                    .cmuxFont(size: 11, monospacedDigit: true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(String(localized: "machines.freeAccess.upgrade", defaultValue: "Upgrade"))
                    .cmuxFont(size: 11)
                    .underline(isHovered)
            }
            .foregroundColor(isExpired ? Color.orange : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .background(Color(nsColor: backgroundColor))
        .help(helpText)
        .accessibilityLabel(text)
        .accessibilityIdentifier("CloudMachinesFreeAccessBanner")
    }

    private var helpText: String {
        String(
            format: String(
                localized: "machines.freeAccess.help",
                defaultValue: "Free plans keep a machine reachable for %d days after it is created. Upgrade to Pro to keep using it."
            ),
            windowDays
        )
    }
}

struct MachinesChromeIconButton: View {
    let symbolName: String
    let accessibilityLabel: String
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isHovered ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
