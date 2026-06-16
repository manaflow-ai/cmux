import CmuxAgentChat
import SwiftUI

/// The horizontal chip row above the composer field: Stop (while working),
/// Esc, Ctrl-C, and Terminal escape-hatch chips.
public struct ChatAccessoryChipRow: View {
    private let agentState: ChatAgentState
    private let onInterrupt: (Bool) -> Void
    private let onOpenTerminal: () -> Void

    /// Creates the chip row.
    ///
    /// - Parameters:
    ///   - agentState: Live agent presence; working adds the Stop chip.
    ///   - onInterrupt: Interrupts the agent (`false` = Esc, `true` =
    ///     Ctrl-C).
    ///   - onOpenTerminal: Opens the session's raw terminal.
    public init(
        agentState: ChatAgentState,
        onInterrupt: @escaping (Bool) -> Void,
        onOpenTerminal: @escaping () -> Void
    ) {
        self.agentState = agentState
        self.onInterrupt = onInterrupt
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if isWorking {
                    chip(
                        label: String(
                            localized: "chat.chip.stop", defaultValue: "Stop", bundle: .module
                        ),
                        tint: .red
                    ) {
                        onInterrupt(false)
                    }
                }
                chip(
                    label: String(localized: "chat.chip.esc", defaultValue: "Esc", bundle: .module)
                ) {
                    onInterrupt(false)
                }
                chip(
                    label: String(
                        localized: "chat.chip.ctrl_c", defaultValue: "Ctrl-C", bundle: .module
                    )
                ) {
                    onInterrupt(true)
                }
                chip(
                    label: String(
                        localized: "chat.chip.terminal", defaultValue: "Terminal", bundle: .module
                    ),
                    action: onOpenTerminal
                )
            }
            // Inset the row content slightly so the fade reveals/clips chips
            // rather than cropping the very first/last chip flush at the edge.
            .padding(.horizontal, 2)
        }
        .frame(height: 32)
        // Soft horizontal scroll-edge fade so chips dissolve at the margins
        // instead of being hard-clipped by the scroll view's straight edge.
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.965),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var isWorking: Bool {
        if case .working = agentState { return true }
        return false
    }

    private func chip(label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(tint ?? .primary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    (tint?.opacity(0.12) ?? Color.secondary.opacity(0.15)),
                    in: .capsule
                )
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
