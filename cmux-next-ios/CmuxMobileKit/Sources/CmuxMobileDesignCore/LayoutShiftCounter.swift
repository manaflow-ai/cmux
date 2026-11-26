#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The layout-shift count (the web's CLS idea, as a count): after the first frame that draws a
/// marked row or card, every display frame in which one of them that was already drawn moves or
/// resizes counts once. Zero is the bound. Leo, 2026-11-24: "the loading has layout shifts and
/// placeholder states that likely dont need to be so placeholder and better diffed".
///
/// Pure frame-to-frame diff, so the rule is tested without a screen (LayoutShiftCounterTests);
/// `LayoutShiftProbe` feeds it once per display frame and `.layoutShiftTracked` marks the rows.
///
/// A row reports its frame in one of two spaces:
/// - `.scrollContent`: its frame in its scroll view's content, which a scroll does not change, so
///   any move or resize there is a shift;
/// - `.window`: its frame on screen (a UIKit-hosted list, where SwiftUI sees no scroll view). A
///   scroll moves every such row by the same amount, so the most common move among them that
///   frame is read as the scroll and only rows that moved otherwise, or resized, count.
public struct LayoutShiftCounter: Sendable {
    public enum Space: String, Sendable { case scrollContent, window }

    public struct Row: Sendable, Equatable {
        public var rect: CGRect
        public var space: Space
        public init(_ rect: CGRect, _ space: Space) {
            self.rect = rect
            self.space = space
        }
    }

    /// Frames counted, from the first that drew a marked row.
    public private(set) var frames = 0
    /// Frames in which at least one drawn row moved or resized.
    public private(set) var shiftFrames = 0
    /// Row moves summed over those frames.
    public private(set) var shiftedRows = 0
    /// The last row that shifted: `id y/h->y/h`.
    public private(set) var lastMoved = ""

    /// Moves and resizes up to this many points are rounding, not a shift.
    public let tolerance: CGFloat
    private var last: [String: Row] = [:]
    private var painted = false

    public init(tolerance: CGFloat = 1) {
        self.tolerance = tolerance
    }

    /// One display frame's marked rows (id -> frame). Returns how many rows shifted in it.
    @discardableResult
    public mutating func frame(_ rows: [String: Row]) -> Int {
        if !painted {
            guard !rows.isEmpty else { return 0 }
            painted = true
        }
        frames += 1
        var moves: [(id: String, before: CGRect, after: CGRect, space: Space)] = []
        for (id, row) in rows {
            guard let before = last[id], before.space == row.space else { continue }
            if differs(before.rect, row.rect) { moves.append((id, before.rect, row.rect, row.space)) }
        }
        last = rows
        guard !moves.isEmpty else { return 0 }

        // Among window-space rows that kept their size, the most common translation is a scroll.
        var counts: [Delta: Int] = [:]
        for move in moves where move.space == .window && !resized(move.before, move.after) {
            counts[Delta(move.before, move.after, tolerance), default: 0] += 1
        }
        let scroll = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        let shifted = moves.filter { move in
            if move.space == .scrollContent || resized(move.before, move.after) { return true }
            return Delta(move.before, move.after, tolerance) != scroll
        }
        guard let first = shifted.min(by: { $0.id < $1.id }) else { return 0 }
        shiftFrames += 1
        shiftedRows += shifted.count
        lastMoved = "\(first.id.prefix(40)) \(Int(first.before.minY))/\(Int(first.before.height))->\(Int(first.after.minY))/\(Int(first.after.height))"
        return shifted.count
    }

    private func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance || resized(a, b)
    }

    private func resized(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }

    /// A translation rounded to the tolerance, so rows a scroll moved alike compare equal.
    private struct Delta: Hashable, Comparable {
        let dx: Int
        let dy: Int
        init(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) {
            let step = max(tolerance, 0.5) * 2
            dx = Int(((b.minX - a.minX) / step).rounded())
            dy = Int(((b.minY - a.minY) / step).rounded())
        }
        static func < (l: Delta, r: Delta) -> Bool { (l.dy, l.dx) < (r.dy, r.dx) }
    }
}
