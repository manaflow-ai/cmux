import CoreGraphics
import Foundation

/// The picture size a viewer needs, and the size the host captures at.
///
/// The viewer reports, every 2 s and when a pinch ends, the long edge in
/// device pixels that the whole streamed display takes on its screen at its
/// zoom (``ScreenStreamViewer/viewDemandMessage``). The host captures at the
/// smallest rung that covers it (960, 1280, 1920, 2560 or 3840 pixels on the
/// long edge, never more than the display), so a phone showing a 3456×2234
/// display 1179 pixels wide gets 1280 instead of the full size, and zooming
/// in brings the full size back.
///
/// A change has to hold before it applies: a smaller picture after 6 s, a
/// larger one after 3 s, and a larger one that undoes a step down taken in
/// the last 30 s after 6 s, so a viewer hovering at a rung boundary can't
/// make the encoder restart every heartbeat. A pinch report raises at once:
/// the person asked for detail. Ported from Petal's
/// `ViewerDemandResolutionState` (https://github.com/kiruna-labs/petal,
/// Apache-2.0, `apps/desktop/src-tauri/src/session/share.rs`).
struct ViewerDemand: Sendable {
    static let rungs = [960, 1280, 1920, 2560, 3840]
    static let downsizeHold: TimeInterval = 6
    static let upsizeHold: TimeInterval = 3
    static let reversalDwell: TimeInterval = 30

    /// The long edge the host captures at; nil: the display's own size.
    private(set) var cap: Int?
    private var pending: (cap: Int?, since: TimeInterval)?
    private var lastChange: (at: TimeInterval, raised: Bool)?

    /// The rung for a viewer's `longEdge` on a display whose long edge is
    /// `displayLongEdge` pixels; nil when the rung is the display's own size
    /// or more (nothing to scale down).
    static func rung(for longEdge: Int, displayLongEdge: Int) -> Int? {
        let rung = rungs.first { $0 >= longEdge } ?? rungs[rungs.count - 1]
        return displayLongEdge > 0 && rung >= displayLongEdge ? nil : rung
    }

    /// Takes one viewer report at `now` (seconds on a monotonic clock) and
    /// returns whether ``cap`` changed. A report of 0 or less carries no size
    /// and changes nothing.
    mutating func report(longEdge: Int, displayLongEdge: Int, pinch: Bool, now: TimeInterval) -> Bool {
        guard longEdge > 0 else {
            pending = nil
            return false
        }
        let target = Self.rung(for: longEdge, displayLongEdge: displayLongEdge)
        guard target != cap else {
            pending = nil
            return false
        }
        let raising = Self.size(target) > Self.size(cap)
        if raising && pinch {
            apply(target, raised: true, now: now)
            return true
        }
        guard let pending, pending.cap == target else {
            // A new target (or a contradicted one) starts its hold now.
            self.pending = (target, now)
            return false
        }
        guard now - pending.since >= hold(raising: raising, now: now) else { return false }
        apply(target, raised: raising, now: now)
        return true
    }

    private mutating func apply(_ target: Int?, raised: Bool, now: TimeInterval) {
        cap = target
        pending = nil
        lastChange = (now, raised)
    }

    private func hold(raising: Bool, now: TimeInterval) -> TimeInterval {
        guard raising else { return Self.downsizeHold }
        if let lastChange, !lastChange.raised, now - lastChange.at < Self.reversalDwell { return Self.downsizeHold }
        return Self.upsizeHold
    }

    /// A cap as a size to compare (nil, the full display, is the largest).
    private static func size(_ cap: Int?) -> Int { cap ?? Int.max }

    /// `size` scaled down to fit `cap` on its long edge (even sides, as the
    /// encoder wants); unchanged when it already fits or there is no cap.
    static func fit(_ size: CGSize, cap: Int?) -> CGSize {
        guard let cap, size.width > 0, size.height > 0 else { return size }
        let longEdge = max(size.width, size.height)
        guard longEdge > CGFloat(cap) else { return size }
        let scale = CGFloat(cap) / longEdge
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}
