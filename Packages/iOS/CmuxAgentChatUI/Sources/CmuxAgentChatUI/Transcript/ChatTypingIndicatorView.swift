import CmuxAgentChat
import SwiftUI

/// The single in-place "agent is working" indicator: three animated dots
/// plus live elapsed time.
///
/// Exactly one instance renders at the transcript tail while the agent
/// works (product rule: working state never spams transcript rows).
public struct ChatTypingIndicatorView: View {
    private let agentState: ChatAgentState

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatBubbleMaxWidth) private var bubbleMaxWidth

    /// Creates the indicator.
    ///
    /// - Parameter agentState: The live agent state; renders content only
    ///   for ``ChatAgentState/working(since:)``.
    public init(agentState: ChatAgentState) {
        self.agentState = agentState
    }

    public var body: some View {
        if case .working(let since) = agentState {
            HStack(spacing: 8) {
                ChatTypingDotsView()
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(
                        Self.elapsedLabel(
                            seconds: max(0, Int(context.date.timeIntervalSince(since)))
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.incomingBubbleFill, in: .rect(cornerRadius: theme.bubbleCornerRadius))
            .frame(maxWidth: typingBubbleMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(
                String(
                    localized: "chat.typing.accessibility",
                    defaultValue: "Agent is working",
                    bundle: .module
                )
            )
        }
    }

    private var typingBubbleMaxWidth: CGFloat {
        bubbleMaxWidth.isFinite ? min(bubbleMaxWidth, 200) : 200
    }

    /// Formats elapsed working time compactly ("5s", "1m 23s", "1h 2m"),
    /// localized through `Duration`'s units format style.
    static func elapsedLabel(seconds: Int) -> String {
        let duration = Duration.seconds(seconds)
        if seconds < 60 {
            return duration.formatted(.units(allowed: [.seconds], width: .narrow))
        }
        if seconds < 3600 {
            return duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
        }
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

/// The three-dot pulse animation inside the typing indicator.
struct ChatTypingDotsView: View {
    @State private var animating = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion || animating ? 1 : 0.3)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
