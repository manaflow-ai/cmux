@testable import CmuxNextDesign
import QuartzCore
import Testing

/// A keyframe animation's value kind (point, size or number) is worked out once per animation, not once per
/// keyframe: the strip's own keyframe paths carry one value per 120 Hz sample, and each value built a String from
/// its `objCType` and searched it (drag.tab_to_pane's light-session stall, MotionPath.point, macOS 27 sweep).
@MainActor @Suite struct MotionPathValueKindTests {
    @Test(arguments: ["position", "bounds.size", "position.x"])
    func aKeyframePathReadsItsValueKindOnce(_ keyPath: String) {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 50, height: 20)
        let values: [Any] = (0..<240).map { index -> Any in
            switch keyPath {
            case "position": NSValue(point: CGPoint(x: Double(index), y: 1))
            case "bounds.size": NSValue(size: CGSize(width: Double(index), height: 1))
            default: NSNumber(value: Double(index))
            }
        }
        let frames = CAKeyframeAnimation(keyPath: keyPath)
        frames.values = values
        frames.duration = 2
        layer.add(frames, forKey: "frames")
        var reads = 0
        let path = MotionPath(layer, keyPath == "position.x" ? "position" : keyPath, now: 100, kindOf: { value in
            reads += 1
            return MotionPath.ValueKind(of: value)
        })
        #expect(reads == 1, "\(reads) value-kind reads for 240 keyframes")
        #expect(path.isExact)
        #expect(abs(path.value(at: 101).x - 120) < 0.6)
    }
}
