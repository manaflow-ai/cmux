import Foundation
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The spring an animation DECLARES, solved by this file's own closed form. The oracle never asks
/// the animator (`SpringValue`, `cmux_motion_step`) where a frame should be (cmux-ad 2026-11-01,
/// rule 2).
///
/// A spring has two declarations: the source token table (`MotionTunables.springDefaults`) and the
/// design token file (plans/cmux-next/spec-proposals/visuals/design-tokens.json, `motion.springs`).
/// They must agree (perf lead 2026-11-01): a difference is recorded as a FINDING failure, never
/// resolved by the test.
struct DeclaredSpring: Equatable, CustomStringConvertible {
    let token: String
    /// Seconds for one undamped oscillation (`motion.springModel`: omega = 2 pi / response, mass 1).
    let response: Double
    let dampingFraction: Double

    var description: String { "\(token) (response \(response) s, damping \(dampingFraction))" }

    /// `token` as it moves under the settings the tests pin: speed fast (time scale 1) and
    /// `ui.animations.bounce` none, under which a structural token (`motion.structural`) is at least
    /// critically damped (`motion.bounce`).
    static func declared(_ token: MotionSpring) throws -> DeclaredSpring {
        guard let source = MotionTunables.springDefaults[token]?.0 else {
            throw Failure(description: "the source token table declares no \(token.rawValue) spring")
        }
        let motion = try designMotion()
        let springs = motion["springs"] as? [String: Any]
        let value = (springs?[token.rawValue] as? [String: Any])?["value"] as? [String: Any]
        let structural = (motion["structural"] as? [String: Any])?["value"] as? [String] ?? []
        if let response = value?["response"] as? Double, let damping = value?["dampingFraction"] as? Double {
            if abs(response - source.response) > 1e-9 || abs(damping - source.dampingFraction) > 1e-9 {
                Issue.record(Comment(rawValue: "FINDING: the \(token.rawValue) spring differs: design-tokens.json \(response)/\(damping), "
                    + "MotionTunables.springDefaults \(source.response)/\(source.dampingFraction)"))
            }
        } else {
            Issue.record("FINDING: design-tokens.json motion.springs declares no \(token.rawValue) spring")
        }
        if structural.contains(token.rawValue) != token.isStructural {
            let only = structural.contains(token.rawValue) ? "design-tokens.json" : "the source"
            Issue.record("FINDING: \(token.rawValue) is structural in \(only) only")
        }
        let damping = structural.contains(token.rawValue) ? max(source.dampingFraction, 1) : source.dampingFraction
        return DeclaredSpring(token: token.rawValue, response: source.response, dampingFraction: damping)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The share of its travel a spring started at rest has covered `time` seconds after it
    /// started (0 before): the closed form of x'' + 2 zeta omega x' + omega^2 x = 0 with x(0) = 1,
    /// x'(0) = -initialVelocity (travels per second), omega = 2 pi / response.
    func progress(at time: Double, initialVelocity: Double = 0) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / response, zeta = dampingFraction, dx0 = -initialVelocity
        let remaining: Double
        if abs(zeta - 1) < 1e-9 {
            remaining = (1 + (dx0 + omega) * time) * exp(-omega * time)
        } else if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot()
            remaining = exp(-zeta * omega * time) * (cos(damped * time) + (dx0 + zeta * omega) / damped * sin(damped * time))
        } else {
            let root = (zeta * zeta - 1).squareRoot()
            let fast = -omega * (zeta + root), slow = -omega * (zeta - root)
            let slowWeight = (dx0 - fast) / (slow - fast)
            remaining = slowWeight * exp(slow * time) + (1 - slowWeight) * exp(fast * time)
        }
        return 1 - remaining
    }

    /// The farthest the spring passes its target, as a share of its travel (0 when it never does).
    var overshoot: Double {
        dampingFraction < 1 ? exp(-dampingFraction * Double.pi / (1 - dampingFraction * dampingFraction).squareRoot()) : 0
    }

    /// The checkout's root, from this file's path (Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/AnimationPixel/).
    static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return url
    }

    private static func designMotion() throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("plans/cmux-next/spec-proposals/visuals/design-tokens.json")
        guard let data = try? Data(contentsOf: url),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let motion = json["motion"] as? [String: Any] else {
            throw Failure(description: "cannot read motion tokens from \(url.path)")
        }
        return motion
    }
}
