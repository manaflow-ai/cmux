import CmuxAgentChat
import SwiftUI

/// The single in-place "agent is working" indicator: a small composing bloom
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
            ChatThinkingBloomView()
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

/// A compact, asymmetric mark that reads as composition instead of waiting.
struct ChatThinkingBloomView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ChatThinkingBloomFrame(phase: 0.18)
        } else {
            TimelineView(.animation) { timeline in
                ChatThinkingBloomFrame(
                    phase: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
    }
}

private struct ChatThinkingBloomFrame: View {
    let phase: TimeInterval

    @Environment(\.chatTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width * 0.48, y: size.height * 0.50)
            let cycle = phase * 1.55
            let turn = cycle * 0.82
            let breath = 0.5 + 0.5 * sin(cycle * 2.0)

            for (index, spoke) in Self.spokes.enumerated() {
                let ordinal = Double(index)
                let lift = 0.5 + 0.5 * sin(cycle * 2.3 + ordinal * 0.86)
                let angle = spoke.angle + turn + sin(cycle + ordinal) * 0.10
                let inner = side * (0.12 + 0.015 * lift)
                let outer = inner + side * spoke.length * (0.82 + 0.22 * lift)
                let opacity = 0.14 + 0.50 * lift
                let width = side * (0.038 + 0.010 * lift)

                context.stroke(
                    radialStroke(center: center, angle: angle, inner: inner, outer: outer),
                    with: .color(theme.accent.opacity(opacity)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round)
                )
            }

            let glintAngle = turn * 1.7 + sin(cycle * 1.3) * 0.45
            let glintRadius = side * (0.28 + 0.05 * breath)
            let glint = CGPoint(
                x: center.x + cos(glintAngle) * glintRadius,
                y: center.y + sin(glintAngle) * glintRadius
            )
            let wake = CGPoint(
                x: center.x + cos(glintAngle - 0.50) * side * 0.18,
                y: center.y + sin(glintAngle - 0.50) * side * 0.18
            )
            context.stroke(
                curvedWake(from: wake, through: center, to: glint),
                with: .color(theme.accent.opacity(0.22 + 0.18 * breath)),
                style: StrokeStyle(lineWidth: side * 0.020, lineCap: .round, lineJoin: .round)
            )
            context.fill(
                Circle().path(in: CGRect(
                    x: glint.x - side * 0.040,
                    y: glint.y - side * 0.040,
                    width: side * 0.080,
                    height: side * 0.080
                )),
                with: .color(.primary.opacity(0.62))
            )
            context.fill(
                Circle().path(in: CGRect(
                    x: center.x - side * 0.032,
                    y: center.y - side * 0.032,
                    width: side * 0.064,
                    height: side * 0.064
                )),
                with: .color(theme.accent.opacity(0.36 + 0.26 * breath))
            )
        }
    }

    private static let spokes: [(angle: Double, length: CGFloat)] = [
        (-1.57, 0.22),
        (-0.74, 0.18),
        (-0.06, 0.25),
        (0.66, 0.16),
        (1.34, 0.22),
        (2.10, 0.14),
        (2.82, 0.24),
        (3.56, 0.17),
    ]

    private func radialStroke(
        center: CGPoint,
        angle: Double,
        inner: CGFloat,
        outer: CGFloat
    ) -> Path {
        Path { path in
            path.move(to: CGPoint(
                x: center.x + cos(angle) * inner,
                y: center.y + sin(angle) * inner
            ))
            path.addLine(to: CGPoint(
                x: center.x + cos(angle) * outer,
                y: center.y + sin(angle) * outer
            ))
        }
    }

    private func curvedWake(from start: CGPoint, through control: CGPoint, to end: CGPoint) -> Path {
        Path { path in
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
        }
    }
}
