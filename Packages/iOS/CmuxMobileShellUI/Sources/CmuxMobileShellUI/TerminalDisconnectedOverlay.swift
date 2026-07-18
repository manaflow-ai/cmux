#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Shown over the terminal when the phone is NOT connected to the workspace's
/// Mac, so a dropped or recovering connection reads as "reconnecting" with an
/// action — never a silent black void (the recurring "black screen" report).
/// Offline (`.unavailable`) offers an explicit Reconnect; `.reconnecting` shows
/// progress. Nothing renders when connected (the caller gates on status).
struct TerminalDisconnectedOverlay: View {
    let status: MobileMacConnectionStatus
    let host: String
    let reconnect: () -> Void

    var body: some View {
        ZStack {
            // Sits over the (black) terminal; the white content is what the user
            // sees instead of an unexplained black screen.
            Rectangle().fill(.black.opacity(0.6)).ignoresSafeArea()
            VStack(spacing: 14) {
                if status == .reconnecting {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Image(systemName: status.symbolName)
                        .font(.system(size: 42))
                        .foregroundStyle(status.tintColor)
                }
                Text(status.label)
                    .font(.headline)
                    .foregroundStyle(.white)
                if !host.isEmpty {
                    Text(host)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                if status == .unavailable {
                    Button(action: reconnect) {
                        Label(
                            L10n.string("mobile.workspace.reconnect", defaultValue: "Reconnect"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityIdentifier("MobileTerminalReconnectButton")
                }
            }
            .padding(28)
        }
        .accessibilityIdentifier("MobileTerminalDisconnectedOverlay")
    }
}
#endif
