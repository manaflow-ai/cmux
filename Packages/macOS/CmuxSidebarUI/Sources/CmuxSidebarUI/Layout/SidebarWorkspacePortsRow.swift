public import CoreGraphics
public import SwiftUI

/// The listening-ports row shown under a workspace row.
///
/// Renders one underlined button per forwarded port; pressing a port calls
/// ``onOpen``. The localized port label and tooltip are resolved by the caller
/// (`portLabel`, `portTooltip`) so this package view holds no app-target
/// localization dependency.
public struct SidebarWorkspacePortsRow: View {
    let ports: [Int]
    let color: Color
    let fontScale: CGFloat
    let portLabel: (Int) -> String
    let portTooltip: (Int) -> String
    let onOpen: (Int) -> Void

    /// Creates the listening-ports row.
    /// - Parameters:
    ///   - ports: The forwarded ports to display, in order.
    ///   - color: Foreground color for the port labels.
    ///   - fontScale: Multiplier applied to the base font size.
    ///   - portLabel: Maps a port to its localized display label.
    ///   - portTooltip: Maps a port to its localized open tooltip.
    ///   - onOpen: Invoked with the port when a label is pressed.
    public init(
        ports: [Int],
        color: Color,
        fontScale: CGFloat,
        portLabel: @escaping (Int) -> String,
        portTooltip: @escaping (Int) -> String,
        onOpen: @escaping (Int) -> Void
    ) {
        self.ports = ports
        self.color = color
        self.fontScale = fontScale
        self.portLabel = portLabel
        self.portTooltip = portTooltip
        self.onOpen = onOpen
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(ports, id: \.self) { port in
                Button(action: {
                    onOpen(port)
                }) {
                    Text(portLabel(port))
                        .underline()
                }
                .buttonStyle(.plain)
                .safeHelp(portTooltip(port))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10 * fontScale, design: .monospaced))
        .foregroundColor(color)
        .lineLimit(1)
    }
}
