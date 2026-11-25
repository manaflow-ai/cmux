public import AppKit

/// Asserts that an anchored edge stays within 1 pt across frames while something animates or relayouts
/// under it (Leo 2026-11-24, of the hover surfaces: "affected by layout shifts when it shouldnt be").
/// A test records the surface's frame once it shows, starts the change (an anchor moving 40 pt, a tab
/// opening, the composer growing) and hands ``sample(frames:step:frame:)`` a closure that reads the frame
/// again; the hold runs the run loop for that many display frames, calls `step` on each (the animation's
/// next frame, a layout pass) and returns the worst drift of the edge from the first frame.
@MainActor
public enum AnchoredEdgeHold {
    /// The most an anchored edge may move, in points.
    public static let tolerance: CGFloat = 1

    /// Which edge holds: the frame's origin (both axes), or one side.
    public enum Edge: Sendable {
        case origin, minX, maxX, minY, maxY

        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            switch self {
            case .origin: max(abs(a.minX - b.minX), abs(a.minY - b.minY))
            case .minX: abs(a.minX - b.minX)
            case .maxX: abs(a.maxX - b.maxX)
            case .minY: abs(a.minY - b.minY)
            case .maxY: abs(a.maxY - b.maxY)
            }
        }
    }

    /// One sampling: the frame it started at, every frame seen and the worst drift.
    public struct Result: Sendable, CustomStringConvertible {
        public let start: CGRect
        public let samples: [CGRect]
        public let drift: CGFloat
        /// Whether the edge stayed within ``AnchoredEdgeHold/tolerance``.
        public var held: Bool { drift <= AnchoredEdgeHold.tolerance }
        public var description: String {
            "the anchored edge moved \(drift) pt from \(start) (samples: \(samples.map { "\($0.origin)" }.joined(separator: ", ")))"
        }
    }

    /// Samples `frame` over `frames` run-loop turns of one display frame each (16 ms), calling `step` first
    /// on each turn, and returns how far `edge` moved from `start` (nil: the first sample).
    public static func sample(_ edge: Edge = .origin, from start: CGRect? = nil, frames: Int = 8,
                              step: () -> Void = {}, frame: () -> CGRect?) -> Result {
        let first = start ?? frame() ?? .null
        var samples: [CGRect] = []
        var drift: CGFloat = 0
        for _ in 0 ..< frames {
            step()
            // test: one display frame of run loop, so deferred layout and animations run.
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
            guard let now = frame() else {
                drift = .infinity
                break
            }
            samples.append(now)
            drift = max(drift, edge.distance(first, now))
        }
        return Result(start: first, samples: samples, drift: drift)
    }
}
