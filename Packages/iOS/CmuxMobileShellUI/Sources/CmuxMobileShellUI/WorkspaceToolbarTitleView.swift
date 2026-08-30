import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceToolbarTitleView: View {
    let title: String
    let subtitle: String?
    let connectionStatus: MobileMacConnectionStatus

    var body: some View {
        HStack(spacing: 6) {
            // Connection state rides the title's existing indicator slot as
            // quiet chrome instead of covering the terminal: a spinner while
            // reconnecting, a red dot while disconnected, the plain dot when
            // healthy. All three share one fixed frame so the title never
            // shifts across transitions.
            Group {
                if connectionStatus == .reconnecting {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.secondary)
                } else {
                    Circle()
                        .fill(
                            connectionStatus == .unavailable
                                ? connectionStatus.tintColor
                                : Color.secondary
                        )
                }
            }
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)

            MobileCompactToolbarTitleStack(title: title, subtitle: subtitleLine)
        }
        .padding(.horizontal, MobileCompactToolbarTitleStack.horizontalContentPadding)
        .accessibilityElement(children: .combine)
        .accessibilityValue(connectionStatus == .connected ? "" : connectionStatus.label)
    }

    private var subtitleLine: String? {
        // A disconnected workspace explains itself on the subtitle line (the
        // input gate blocks typing in that state, so the red dot alone would
        // read as a silently dead keyboard). Reconnecting keeps the normal
        // subtitle: the spinner carries that state and typing still works.
        if connectionStatus == .unavailable {
            return connectionStatus.label
        }
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }
}
