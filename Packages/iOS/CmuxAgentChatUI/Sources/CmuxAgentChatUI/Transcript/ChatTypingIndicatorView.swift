import CmuxAgentChat
import SwiftUI

/// The single in-place "agent is working" indicator: a small breathing trace
/// at the transcript tail.
///
/// Exactly one instance renders at the transcript tail while the agent
/// works (product rule: working state never spams transcript rows).
public struct ChatTypingIndicatorView: View {
    private let agentState: ChatAgentState

    /// Creates the indicator.
    ///
    /// - Parameter agentState: The live agent state; renders content only
    ///   for ``ChatAgentState/working(since:)``.
    public init(agentState: ChatAgentState) {
        self.agentState = agentState
    }

    public var body: some View {
        if case .working = agentState {
            ChatThinkingTraceView()
                .frame(width: 34, height: 34)
                .padding(.leading, 2)
                .padding(.vertical, 4)
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
}

/// A compact original progress mark for the transcript tail.
struct ChatThinkingTraceView: View {
    @State private var rotating = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatTheme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.16), lineWidth: 1.5)
                .frame(width: 18, height: 18)
            Circle()
                .trim(from: 0.10, to: 0.52)
                .stroke(
                    AngularGradient(
                        colors: [
                            theme.accent.opacity(0.18),
                            theme.accent.opacity(0.95),
                            .white.opacity(0.66),
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(rotating ? 360 : 0))
            Circle()
                .trim(from: 0.68, to: 0.80)
                .stroke(
                    .secondary.opacity(reduceMotion ? 0.42 : (rotating ? 0.18 : 0.52)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(rotating ? -240 : 0))
        }
        .animation(
            reduceMotion ? nil : .linear(duration: 1.45).repeatForever(autoreverses: false),
            value: rotating
        )
        .onAppear { rotating = true }
    }
}
