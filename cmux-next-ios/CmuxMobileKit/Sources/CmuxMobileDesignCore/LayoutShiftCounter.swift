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
/// - `.window`: its frame in its list's visible bounds (a UIKit list reports its cells' frames less
///   its content offset; a SwiftUI row its frame in its scroll view's visible bounds). A scroll
///   moves every such row by the same amount, so the most common move among them that frame is
///   read as the scroll and only rows that moved otherwise (by more than the tolerance), or
///   resized, count.
///
/// A row may carry its content's revision (`content`). A row that resizes at a revision other than
/// the one its last size was drawn for (the list may lay the new content out a frame after the
/// revision lands) drew new content (a streamed token, a tool call's output): as the web's CLS does not count
/// an element growing, its resize is not a shift, and it counts only when neither its top nor its
/// bottom edge stayed put (with the frame's scroll, in `.window` space). The rows its growth pushed
/// still count. A resize at the same revision (an estimated height measured late) still counts.
///
/// Neither space is the screen: as the web's CLS leaves out CSS transforms, a list scaled or moved
/// whole (the tab grid's zoom, the live page riding its card on the grid, a push) shifts nothing
/// in it. Only rows inside their list's visible bounds are reported (the CLS viewport).
public struct LayoutShiftCounter: Sendable {
    public enum Space: String, Sendable { case scrollContent, window }

    public struct Row: Sendable, Equatable {
        public var rect: CGRect
        public var space: Space
        /// The revision of what the row draws, when its list knows it (nil: unknown, so any resize
        /// counts).
        public var content: Int?
        public init(_ rect: CGRect, _ space: Space, content: Int? = nil) {
            self.rect = rect
            self.space = space
            self.content = content
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
    /// The first `movesKept` shifts, each `frame:id y/h->y/h` (a list row's with `dy`, `dh` and the
    /// frame's `scroll`, to a tenth of a point; one per shifted row), so a run's
    /// record says when and how a row moved, not only its last move.
    public private(set) var moves: [String] = []
    public static let movesKept = 24

    /// Moves and resizes up to this many points are rounding, not a shift.
    public let tolerance: CGFloat
    private var last: [String: Row] = [:]
    /// Each drawn row's revision when it took its current size.
    private var sizedFor: [String: Int] = [:]
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
        var moves: [(id: String, before: CGRect, after: CGRect, space: Space, grew: Bool)] = []
        for (id, row) in rows {
            guard let before = last[id], before.space == row.space else { continue }
            let drawnFor = sizedFor[id] ?? before.content
            let grew = resized(before.rect, row.rect) && drawnFor != nil && row.content != nil && drawnFor != row.content
            if differs(before.rect, row.rect) { moves.append((id, before.rect, row.rect, row.space, grew)) }
        }
        var sized: [String: Int] = [:]
        for (id, row) in rows {
            let kept = last[id].map { !resized($0.rect, row.rect) } ?? false
            if let content = kept ? sizedFor[id] ?? row.content : row.content { sized[id] = content }
        }
        sizedFor = sized
        last = rows
        guard !moves.isEmpty else { return 0 }

        // Among window-space rows that kept their size, the most common translation is a scroll;
        // not rows below a row that grew that moved down: that growth pushed them (the web's CLS
        // case of content landing above what the reader reads).
        let growth = moves.filter { $0.grew }.map { $0.before }
        let pushed: (CGRect, CGRect) -> Bool = { before, after in
            after.minY - before.minY > self.tolerance && growth.contains { before.minY >= $0.maxY - self.tolerance }
        }
        let scrolled = moves.filter { $0.space == .window && !resized($0.before, $0.after) && !pushed($0.before, $0.after) }
        var counts: [Delta: Int] = [:]
        for move in scrolled {
            counts[Delta(move.before, move.after, tolerance), default: 0] += 1
        }
        let bucket = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        // The scroll's own translation: the mean of the moves in the winning bucket. A row is the
        // scroll when it moved within the tolerance of it, so rows the same scroll moved by -2.9 and
        // -3.1 pt (either side of a bucket's edge) are not read as one row moving against the rest.
        var scroll: (dx: CGFloat, dy: CGFloat)?
        if let bucket {
            let alike = scrolled.filter { Delta($0.before, $0.after, tolerance) == bucket }
            let n = CGFloat(alike.count)
            scroll = (alike.reduce(0) { $0 + $1.after.minX - $1.before.minX } / n,
                      alike.reduce(0) { $0 + $1.after.minY - $1.before.minY } / n)
        }
        let shifted = moves.filter { move in
            // New content: one of its edges held still (less the scroll) is the row growing.
            if move.grew {
                let held = (dx: move.space == .window ? scroll?.dx ?? 0 : 0, dy: move.space == .window ? scroll?.dy ?? 0 : 0)
                guard abs(move.after.minX - move.before.minX - held.dx) <= tolerance else { return true }
                return abs(move.after.minY - move.before.minY - held.dy) > tolerance
                    && abs(move.after.maxY - move.before.maxY - held.dy) > tolerance
            }
            if move.space == .scrollContent || resized(move.before, move.after) { return true }
            guard let scroll else { return true }
            return abs(move.after.minX - move.before.minX - scroll.dx) > tolerance
                || abs(move.after.minY - move.before.minY - scroll.dy) > tolerance
        }
        guard let first = shifted.min(by: { $0.id < $1.id }) else { return 0 }
        shiftFrames += 1
        shiftedRows += shifted.count
        lastMoved = Self.describe(first.id, first.before, first.after)
        for move in shifted.sorted(by: { $0.id < $1.id }) where self.moves.count < Self.movesKept {
            var entry = "\(frames):\(Self.describe(move.id, move.before, move.after))"
            // A list row: its exact move and resize, and the scroll it was read against, so a
            // run's record tells a row moving against a scroll from a scroll split by rounding.
            if move.space == .window {
                entry += String(format: " dy %.1f dh %.1f", Double(move.after.minY - move.before.minY), Double(move.after.height - move.before.height))
                if let scroll { entry += String(format: " scroll %.1f", Double(scroll.dy)) }
            }
            self.moves.append(entry)
        }
        return shifted.count
    }

    private static func describe(_ id: String, _ before: CGRect, _ after: CGRect) -> String {
        "\(id.prefix(40)) \(Int(before.minY))/\(Int(before.height))->\(Int(after.minY))/\(Int(after.height))"
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
