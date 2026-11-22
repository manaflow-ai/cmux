public import AppKit
public import CmuxAgentQuestion

/// The question card as a transcript row, in the shape of the MessagesLab
/// custom-row seam (measure, make, configure, height change): Home registers
/// it for `question` parts once the seam lands. Measuring is main-actor
/// only and deterministic per (question, width, style).
public struct AgentQuestionRowProvider {
    public var style: AgentQuestionCardStyle
    /// The person submitted or declined; the host sends the op.
    public var onSubmit: (AgentQuestion, AgentQuestionAnswer) -> Void
    public var onDecline: (AgentQuestion) -> Void

    public init(style: AgentQuestionCardStyle = .init(), onSubmit: @escaping (AgentQuestion, AgentQuestionAnswer) -> Void,
                onDecline: @escaping (AgentQuestion) -> Void) {
        self.style = style
        self.onSubmit = onSubmit
        self.onDecline = onDecline
    }

    /// The row height before interaction; a configured view reports later
    /// changes through `heightDidChange`.
    public func measure(_ question: AgentQuestion, width: CGFloat) -> CGFloat {
        AgentQuestionCardView.height(for: question, width: width, style: style)
    }

    public func makeView() -> AgentQuestionCardView { AgentQuestionCardView() }

    /// Recycled views keep a pending ask's local choices when the same ask
    /// comes back (`configure` compares question ids).
    public func configure(_ view: AgentQuestionCardView, question: AgentQuestion, width: CGFloat,
                          heightDidChange: @escaping () -> Void) {
        view.onSubmit = onSubmit
        view.onDecline = onDecline
        view.onHeightChange = heightDidChange
        view.configure(question: question, width: width, style: style)
    }
}
