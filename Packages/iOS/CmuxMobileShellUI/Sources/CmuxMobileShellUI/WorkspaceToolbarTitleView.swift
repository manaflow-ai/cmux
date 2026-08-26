import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceToolbarTitleView: View {
    let title: String
    let subtitle: String?
    let isReconnecting: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Reconnecting rides the title's existing indicator slot as a
            // quiet spinner instead of louder terminal-covering chrome; the
            // dot and spinner share one fixed frame so the title never
            // shifts on the transition.
            Group {
                if isReconnecting {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.secondary)
                } else {
                    Circle()
                        .fill(Color.secondary)
                }
            }
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)

            MobileCompactToolbarTitleStack(title: title, subtitle: subtitleLine)
        }
        .padding(.horizontal, MobileCompactToolbarTitleStack.horizontalContentPadding)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isReconnecting ? MobileMacConnectionStatus.reconnecting.label : "")
    }

    private var subtitleLine: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }
}
