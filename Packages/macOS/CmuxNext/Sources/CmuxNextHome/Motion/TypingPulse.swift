import CmuxNextDesign
import QuartzCore

/// The typing indicator's dots: a staggered opacity pulse on the render
/// server, period from the `pulse` loop token; static while loops may not
/// animate (Reduce Motion, animations off).
@MainActor
enum TypingPulse {
    static func apply(to dot: CALayer, index: Int) {
        guard let period = Motion.period(.pulse), Motion.animatesLoops else {
            dot.removeAnimation(forKey: "pulse")
            dot.opacity = 1
            return
        }
        guard dot.animation(forKey: "pulse") == nil else { return }
        // motion-allow: repeating loop whose period is the pulse loop token
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 1
        pulse.duration = period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.beginTime = dot.convertTime(CACurrentMediaTime(), from: nil) + Double(index) * period / 6
        pulse.fillMode = .backwards
        dot.opacity = 0.35
        dot.add(pulse, forKey: "pulse")
    }
}
