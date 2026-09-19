import CmuxSidebar
import SwiftUI

/// Value-only row, including an independent hover target for the checks glyph.
struct SidebarPullRequestRow: View {
    let display: SidebarWorkspaceSnapshotBuilder.PullRequestDisplay
    let fontScale: CGFloat
    let font: Font
    let foreground: Color
    let clickable: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if clickable {
                Button(action: onOpen) { label }
                    .buttonStyle(.plain)
                    .safeHelp(String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open pull request"))
            } else {
                label
            }
            if let checks = display.checks {
                SidebarPullRequestChecksIcon(checks: checks, pointSize: 9 * fontScale, neutralColor: foreground)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .font(font)
        .foregroundStyle(foreground)
        .opacity(display.isStale ? 0.5 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SidebarPullRequestRow")
    }

    private var label: some View {
        HStack(spacing: 4) {
            PullRequestStatusIcon(status: display.status, color: foreground, fontScale: fontScale)
            Text("\(display.label) #\(display.number)")
                .underline(clickable).lineLimit(1).truncationMode(.tail)
            Text(statusLabel(display.status)).lineLimit(1).fixedSize()
        }
    }

    private func statusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

}
