import CoreGraphics

/// The frame check of the motion spec (leo-workspace `design/motion.md`, Leo 2026-11-06: "We don't have, like, a target
/// evidently"): a motion is one state transition, so every element it moves goes from where it shows to where it rests
/// and nowhere else. A trace records, frame by frame, where each tracked element shows (one coordinate, in window points)
/// and how far its container's edges moved that frame, then finds every frame that breaks a target:
/// - away: the element is farther from its rest than in the frame before (an overshoot, or a jolt "all the way down and
///   then back up");
/// - jump: the element moved more in one frame than its container's edges did (a snap or a pop-in mid-motion);
/// - after the end: the element moves after the motion landed (a layout jump once the animation ended).
/// Built for the frame-owner path's manual 120 Hz ticks (`LayoutRootView.advanceFrame`); dropped frames are the
/// films' and benches' to count, not this check's.
struct MotionFrameTrace {
    struct Sample {
        var position: CGFloat
        /// The largest move of the element's container's edges since the frame before; nil when the element is itself a
        /// moving edge (a pane's), which only the away and after-the-end targets check.
        var containerStep: CGFloat?
    }

    /// The slack below which a difference is rounding (a 2x backing pixel is 0.5 pt).
    static let tolerance: CGFloat = 0.5

    private(set) var tracks: [String: [Sample]] = [:]
    private(set) var settled: [String: CGFloat] = [:]

    /// Where `element` shows in this frame, and how far its container's edges moved since the last frame (zero when the
    /// container does not move: then any move of the element is a jump; nil for a moving edge itself).
    mutating func record(_ element: String, _ position: CGFloat, containerStep: CGFloat? = 0) {
        tracks[element, default: []].append(Sample(position: position, containerStep: containerStep.map(abs)))
    }

    /// Where `element` shows after the landing and one more layout pass: its rest, the target of every frame.
    mutating func settle(_ element: String, _ position: CGFloat) {
        settled[element] = position
    }

    struct Violation: CustomStringConvertible {
        enum Kind: String { case away, jump, afterEnd = "after the end" }
        var element: String
        var frame: Int
        var kind: Kind
        var points: CGFloat
        var description: String { "\(element) frame \(frame): \(kind.rawValue) \(String(format: "%.1f", points)) pt" }
    }

    /// Every frame that breaks a target. Frame 0 is the first recorded (the frame before the motion starts).
    var violations: [Violation] {
        var found: [Violation] = []
        for (element, samples) in tracks.sorted(by: { $0.key < $1.key }) {
            guard let rest = settled[element] ?? samples.last?.position else { continue }
            for (frame, (before, now)) in zip(samples, samples.dropFirst()).enumerated() {
                let away = abs(now.position - rest) - abs(before.position - rest)
                if away > Self.tolerance { found.append(Violation(element: element, frame: frame + 1, kind: .away, points: away)) }
                guard let step = now.containerStep else { continue }
                let jump = abs(now.position - before.position) - step
                if jump > Self.tolerance { found.append(Violation(element: element, frame: frame + 1, kind: .jump, points: jump)) }
            }
            if let last = samples.last, let settledAt = settled[element], abs(settledAt - last.position) > Self.tolerance {
                found.append(Violation(element: element, frame: samples.count, kind: .afterEnd, points: abs(settledAt - last.position)))
            }
        }
        return found
    }

    /// One line for a PR's before and after table: frames, frames that break a target, and the worst of each kind.
    var summary: String {
        let all = violations
        let frames = tracks.values.map(\.count).max() ?? 0
        func worst(_ kind: Violation.Kind) -> String {
            String(format: "%.1f", all.filter { $0.kind == kind }.map(\.points).max() ?? 0)
        }
        let bad = Set(all.map { "\($0.element)#\($0.frame)" }).count
        return "frames \(frames), bad \(bad), worst away \(worst(.away)) pt, worst jump \(worst(.jump)) pt, after end \(worst(.afterEnd)) pt"
    }
}
