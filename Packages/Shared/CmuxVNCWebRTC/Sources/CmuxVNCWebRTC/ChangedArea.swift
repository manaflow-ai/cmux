import CoreGraphics
import Foundation

/// How much of the picture changed lately, from the capture's damage
/// (ScreenCaptureKit's `dirtyRects`), and the bitrate ceiling that earns: a
/// typed line needs a sliver of what a full-screen scroll does (RFD 0088
/// slice 3b). The ceiling rises at once on a bigger change and falls once
/// the change has been small for ``window``.
struct ChangedArea: Sendable {
    /// How long a change keeps its ceiling.
    static let window: UInt64 = 1_000_000_000
    /// The least ceiling: a small change still gets sharp text at once.
    static let floorBitrate = 500_000

    private var recent: [(at: UInt64, fraction: Double)] = []

    /// One picture's changed rects in a `size` picture, at `now` (ns). Returns the share it changed (0–1).
    @discardableResult
    mutating func add(_ rects: [CGRect], in size: CGSize, now: UInt64) -> Double {
        let total = Double(size.width * size.height)
        guard total > 0 else { return 0 }
        let bounds = CGRect(origin: .zero, size: size)
        // Overlapping rects count twice: the ceiling errs high, never low.
        let changed = rects.reduce(0.0) { sum, rect in
            let clipped = rect.intersection(bounds)
            return clipped.isNull ? sum : sum + Double(clipped.width * clipped.height)
        }
        let fraction = min(changed / total, 1)
        recent.removeAll { now &- $0.at > Self.window }
        recent.append((now, fraction))
        return fraction
    }

    /// The largest share changed within ``window`` of `now` (0 when nothing changed).
    func fraction(now: UInt64) -> Double {
        recent.lazy.filter { now &- $0.at <= Self.window }.map(\.fraction).max() ?? 0
    }

    /// The ceiling for a stream whose full ceiling is `full` when `fraction` of it changes:
    /// the full ceiling's share for the changed pixels, never under ``floorBitrate`` (nor over `full`).
    static func ceiling(full: Int, fraction: Double) -> Int {
        min(full, max(floorBitrate, Int((Double(full) * fraction).rounded())))
    }

    /// Whether a ceiling of `next` is worth a sender update from `current`
    /// (any rise; a fall of more than a quarter).
    static func worthApplying(_ next: Int, over current: Int?) -> Bool {
        guard let current else { return true }
        return next > current || Double(next) < Double(current) * 0.75
    }
}
