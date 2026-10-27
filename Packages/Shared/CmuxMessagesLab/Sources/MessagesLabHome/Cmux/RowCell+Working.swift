import AppKit

/// cmux's working indicator: fixed opacity and geometry, with only rotation animated.
@MainActor
extension RowCell {
    static func makeTypingSpinner() -> CAShapeLayer {
        let spinner = CAShapeLayer()
        spinner.actions = ["transform": NSNull(), "strokeColor": NSNull()]
        let bubble = RowDraw.typingBubble
        spinner.frame = CGRect(x: bubble.midX - 7, y: bubble.midY - 7, width: 14, height: 14)
        spinner.fillColor = nil
        spinner.lineWidth = 1.75
        spinner.lineCap = .round
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: 7, y: 7), radius: 6, startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
        spinner.path = arc
        return spinner
    }

    func startTypingSpinner(begin: CFTimeInterval) {
        typingSpinnerActive = true
        typingSpinner.removeAnimation(forKey: "workingSpin")
        guard !MessagesLabHomeView.reducesMotion, MessagesLabHomeView.voiceMotionGate(),
              Springs.typingStillPhase == nil else { return }
        // motion: allow the host's Home motion gate and Reduce Motion above govern this render-server loop.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.beginTime = begin
        typingSpinner.add(spin, forKey: "workingSpin")
    }

    func stopTypingSpinner() {
        typingSpinnerActive = false
        typingSpinner.removeAnimation(forKey: "workingSpin")
    }
}
