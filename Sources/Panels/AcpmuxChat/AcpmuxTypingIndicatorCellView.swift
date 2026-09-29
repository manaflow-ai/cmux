import AppKit

/// Three pulsing dots in an assistant bubble, shown while a turn has no output yet.
final class AcpmuxTypingIndicatorCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("acpmuxChat.typing")

    private let bubbleLayer = CAShapeLayer()
    private var dots: [CALayer] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layer?.addSublayer(bubbleLayer)
        for _ in 0..<3 {
            let dot = CALayer()
            dot.cornerRadius = 3.5
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(layout: AcpmuxRowLayout, theme: AcpmuxChatTheme, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = layout.surfaceFrame
        bubbleLayer.fillColor = theme.assistantBubble.cgColor
        bubbleLayer.path = layout.surfacePath
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = theme.secondaryText.cgColor
            dot.frame = CGRect(x: frame.minX + 14 + CGFloat(index) * 12, y: frame.midY - 3.5, width: 7, height: 7)
        }
        CATransaction.commit()
        startAnimating(reduceMotion: reduceMotion)
    }

    private func startAnimating(reduceMotion: Bool) {
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.35
            fade.toValue = 1
            let group = CAAnimationGroup()
            var animations: [CAAnimation] = [fade]
            if !reduceMotion {
                let bounce = CABasicAnimation(keyPath: "transform.translation.y")
                bounce.fromValue = 0
                bounce.toValue = -3
                animations.append(bounce)
            }
            group.animations = animations
            group.duration = 0.45
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.beginTime = now + Double(index) * 0.15
            group.fillMode = .backwards
            dot.add(group, forKey: "typing")
        }
    }
}
