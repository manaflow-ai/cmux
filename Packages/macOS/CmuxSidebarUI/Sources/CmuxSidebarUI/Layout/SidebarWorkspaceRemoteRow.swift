public import CoreGraphics
public import SwiftUI

/// The remote/SSH connection line shown under a workspace row.
///
/// Renders the remote host text, the connection-status caption, and an optional
/// reconnect button. The caller resolves all colors from the active/inverted
/// foreground ramp and passes them in as values, so this package view carries no
/// app-target color dependency. The reconnect action is delivered as the
/// ``onReconnect`` closure; the view never reaches into a workspace model.
///
/// The owning row decides whether to show this section at all (the SSH-detail
/// toggle and the presence of a remote host); when shown, the host text is
/// always present, so ``hostText`` is non-optional here.
public struct SidebarWorkspaceRemoteRow: View {
    let hostText: String
    let connectionStatusText: String
    let showsReconnectAffordance: Bool
    let stateHelpText: String
    let hostColor: Color
    let statusColor: Color
    let reconnectColor: Color
    let fontScale: CGFloat
    let topPadding: CGFloat
    let onReconnect: () -> Void

    /// Creates the remote row.
    /// - Parameters:
    ///   - hostText: Monospaced remote host/target string shown leading.
    ///   - connectionStatusText: Short connection-status caption shown trailing.
    ///   - showsReconnectAffordance: Whether to show the reconnect button.
    ///   - stateHelpText: Tooltip describing the remote connection state.
    ///   - hostColor: Foreground color for the host text.
    ///   - statusColor: Foreground color for the status caption.
    ///   - reconnectColor: Foreground color for the reconnect button.
    ///   - fontScale: Multiplier applied to the row's font sizes.
    ///   - topPadding: Leading top padding (varies with whether a subtitle is shown).
    ///   - onReconnect: Invoked when the reconnect button is pressed.
    public init(
        hostText: String,
        connectionStatusText: String,
        showsReconnectAffordance: Bool,
        stateHelpText: String,
        hostColor: Color,
        statusColor: Color,
        reconnectColor: Color,
        fontScale: CGFloat,
        topPadding: CGFloat,
        onReconnect: @escaping () -> Void
    ) {
        self.hostText = hostText
        self.connectionStatusText = connectionStatusText
        self.showsReconnectAffordance = showsReconnectAffordance
        self.stateHelpText = stateHelpText
        self.hostColor = hostColor
        self.statusColor = statusColor
        self.reconnectColor = reconnectColor
        self.fontScale = fontScale
        self.topPadding = topPadding
        self.onReconnect = onReconnect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(hostText)
                    .font(.system(size: 10 * fontScale, design: .monospaced))
                    .foregroundColor(hostColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Text(connectionStatusText)
                    .font(.system(size: 9 * fontScale, weight: .medium))
                    .foregroundColor(statusColor)
                    .lineLimit(1)

                if showsReconnectAffordance {
                    Button {
                        onReconnect()
                    } label: {
                        Label(
                            String(localized: "sidebar.remote.reconnect.button", defaultValue: "Reconnect", bundle: .main),
                            systemImage: "arrow.clockwise"
                        )
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9 * fontScale, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(reconnectColor)
                    .safeHelp(String(
                        format: String(
                            localized: "sidebar.remote.reconnect.help",
                            defaultValue: "Reconnect to %@",
                            bundle: .main
                        ),
                        locale: .current,
                        hostText
                    ))
                }
            }
        }
        .padding(.top, topPadding)
        .safeHelp(stateHelpText)
    }
}
