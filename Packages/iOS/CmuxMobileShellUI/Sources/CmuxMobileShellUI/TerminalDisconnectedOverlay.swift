#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import CMUXMobileCore
import SwiftUI

/// Shown over the terminal when the phone is NOT connected to the workspace's
/// Mac, so a dropped or recovering connection reads as "reconnecting" with an
/// action — never a silent black void (the recurring "black screen" report).
/// Offline (`.unavailable`) offers an explicit Reconnect; `.reconnecting` shows
/// progress. Nothing renders when connected (the caller gates on status).
struct TerminalDisconnectedOverlay: View {
    let status: MobileMacConnectionStatus
    let host: String
    let theme: TerminalTheme
    let reconnect: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(theme.terminalBackgroundColor.opacity(0.82)).ignoresSafeArea()
            VStack(spacing: 14) {
                if status == .reconnecting {
                    ProgressView().controlSize(.large).tint(theme.terminalChromeForegroundColor)
                } else {
                    Image(systemName: status.symbolName)
                        .font(.system(size: 42))
                        .foregroundStyle(status.tintColor)
                }
                Text(status.label)
                    .font(.headline)
                    .foregroundStyle(theme.terminalChromeForegroundColor)
                // The generic, always-accurate per-status description. We don't
                // surface the store's classified `connectionError` here because
                // it is a single global foreground/pairing error not keyed per
                // Mac, so on a multi-Mac session it could describe a different
                // Mac. The precise reachability reason is available via the
                // Computers screen's per-route Ping instead.
                Text(status.description)
                    .font(.subheadline)
                    .foregroundStyle(theme.terminalChromeForegroundColor.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !host.isEmpty {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(theme.terminalChromeForegroundColor.opacity(0.55))
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
