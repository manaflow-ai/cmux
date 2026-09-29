import AppKit

/// The transient bubble that carries sent text from the composer into the transcript.
@MainActor
final class AcpmuxMorphBubbleView: AcpmuxFlippedView {
    private let label = NSTextField(wrappingLabelWithString: "")

    init(text: String, theme: AcpmuxChatTheme, frame: CGRect) {
        super.init(frame: frame)
        layer?.cornerRadius = 17
        layer?.backgroundColor = theme.userBubble.withAlphaComponent(0).cgColor
        label.stringValue = text
        label.font = theme.bodyFont
        label.textColor = theme.foreground
        label.isSelectable = false
        label.autoresizingMask = [.width, .height]
        label.frame = bounds.insetBy(dx: 0, dy: 0)
        addSubview(label)
    }

    /// Animates into the bubble at `target` with a slight overshoot, then calls `completion`.
    func morph(to target: CGRect, theme: AcpmuxChatTheme, completion: @escaping @MainActor () -> Void) {
        let horizontal = AcpmuxRowLayoutEngine.bubbleHorizontalPadding
        let vertical = AcpmuxRowLayoutEngine.bubbleVerticalPadding
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            // Control points past 1.0 overshoot, the spring settle of an iMessage send.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.95, 0.3, 1.12)
            context.allowsImplicitAnimation = true
            animator().frame = target
            label.animator().frame = CGRect(x: horizontal, y: vertical, width: target.width - 2 * horizontal, height: target.height - 2 * vertical)
            layer?.backgroundColor = theme.userBubble.cgColor
            label.animator().textColor = theme.userText
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }
}
