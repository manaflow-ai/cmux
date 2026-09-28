import CmuxAppKitSupportUI
import CmuxCloud
import AppKit
import SwiftUI

/// One line under the header on free plans: how long the fleet stays
/// reachable, counting down to the earliest machine's expiry, and the way out
/// (the whole line is the upgrade affordance — the same Pro flow the ＋ button
/// opens at the machine ceiling).
struct MachinesFreeAccessBanner: View {
    let text: String
    let isExpired: Bool
    let windowDays: Int
    let backgroundColor: NSColor
    let onDismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
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
            }
            .buttonStyle(.plain)
            .foregroundColor(isExpired ? Color.orange : .secondary)
            .accessibilityLabel(text)
            .layoutPriority(1)
            CloudBannerDismissButton(action: onDismiss)
        }
        .padding(.horizontal, CloudSidebarChromeMetrics.barHorizontalPadding)
        .padding(.vertical, CloudSidebarChromeMetrics.barVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundColor(isExpired ? Color.orange : .secondary)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .background(Color(nsColor: backgroundColor))
        .help(helpText)
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
                    // The glyph draws into the whole button canvas, centered
                    // by its visible pixels. Centering its layout box instead
                    // leaves glyphs like `trash` a point low.
                    CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                        source: symbolSource,
                        size: NSSize(width: 22, height: 20),
                        tintColor: isHovered ? .labelColor : .secondaryLabelColor,
                        symbolWeight: .medium,
                        fallbackSource: symbolSource,
                        symbolPointSize: 11,
                        centersVisibleContent: true
                    ))
                    .accessibilityHidden(true)
                }
            }
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isHovered ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.buttonCornerRadius, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbolSource: CmuxResolvedIconSource {
        .systemSymbol(name: symbolName, accessibilityDescription: nil)
    }
}
