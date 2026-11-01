import Foundation
import CmuxNextDesignTokens
import Testing

/// A fade as it is DECLARED: its duration from the source token table (`MotionTunables.fadeDefaults`)
/// and from plans/cmux-next/spec-proposals/visuals/design-tokens.json (`motion.fades`), which must
/// agree (a difference is a FINDING), and the fade curve both name (`motion.fadeCurve`: easeOut,
/// cubic-bezier(0, 0, 0.58, 1)), solved here, never read from the animator.
struct DeclaredFade: CustomStringConvertible {
    let token: String
    let duration: Double
    /// The curve's control points (x1, y1, x2, y2).
    static let easeOut = (0.0, 0.0, 0.58, 1.0)

    var description: String { "\(token) (\(Int((duration * 1000).rounded())) ms, easeOut)" }

    static func declared(_ token: MotionFade) throws -> DeclaredFade {
        guard let source = MotionTunables.fadeDefaults[token]?.0 else {
            throw DeclaredSpring.Failure(description: "the source token table declares no \(token.rawValue) fade")
        }
        let url = DeclaredSpring.repositoryRoot.appendingPathComponent("plans/cmux-next/spec-proposals/visuals/design-tokens.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let motion = json?["motion"] as? [String: Any]
        let fades = (motion?["fades"] as? [String: Any]).map { ($0["value"] as? [String: Any]) ?? $0 }
        let declared = (fades?[token.rawValue] as? [String: Any])?["value"] as? Double
        if let declared, abs(declared - source) > 1e-9 {
            Issue.record("FINDING: the \(token.rawValue) fade differs: design-tokens.json \(declared) s, MotionTunables.fadeDefaults \(source) s")
        } else if declared == nil {
            Issue.record("FINDING: design-tokens.json motion.fades declares no \(token.rawValue) fade")
        }
        let curve = ((motion?["fadeCurve"] as? [String: Any])?["value"] as? String) ?? ""
        if !curve.contains("0, 0, 0.58, 1") {
            Issue.record("FINDING: design-tokens.json motion.fadeCurve is \"\(curve)\", not easeOut cubic-bezier(0, 0, 0.58, 1)")
        }
        return DeclaredFade(token: token.rawValue, duration: source)
    }

    /// The opacity share (0...1) `elapsed` seconds into the fade.
    func progress(at elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        guard elapsed < duration else { return 1 }
        let (x1, y1, x2, y2) = Self.easeOut, target = elapsed / duration
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
        // x(t) is monotonic on 0...1: bisect for the parameter, then read y.
        var low = 0.0, high = 1.0
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if bezier(mid, x1, x2) < target { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, y1, y2)
    }
}
