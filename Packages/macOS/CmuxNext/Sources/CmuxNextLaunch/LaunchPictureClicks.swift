public import AppKit

/// The clicks ``LaunchPictureInput`` holds while a part of the window is still its picture, in
/// the order pressed: which to send again when the part's region goes live, and which to drop.
///
/// A held click is its mouse-down and, once it came, its mouse-up. When its part leaves at its region's first content
/// and the model the part shows reads the same as at the press, within the limit, both go again in order; a
/// mouse-up that comes after its mouse-down went follows it at once. Any other held click is dropped: the point
/// means something else now (another workspace shows), it waited too long, the window changed size, or the picture left at its bound.
///
/// ```swift
/// var clicks = LaunchPictureClicks(limit: .seconds(2))
/// clicks.press(down, part: "pane", stamp: "ws-1", at: now)
/// _ = clicks.release(up)                                      // [] (it waits with its press)
/// clicks.partDidGoLive("pane", stamp: "ws-1", at: now)        // [down, up]
/// ```
public struct LaunchPictureClicks {
    struct Held {
        let down: NSEvent
        var up: NSEvent?
        let part: String
        let stamp: String?
        let at: ContinuousClock.Instant
        /// The mouse-down went out already: its mouse-up follows it at once.
        var sent = false
    }

    private var held: [Held] = []
    private let limit: Duration

    public init(limit: Duration) { self.limit = limit }

    /// Clicks still waiting for their part.
    public var count: Int { held.count(where: { !$0.sent }) }

    /// A mouse-down on `part`, whose model reads `stamp` now.
    public mutating func press(_ down: NSEvent, part: String, stamp: String?, at: ContinuousClock.Instant) {
        held.append(Held(down: down, part: part, stamp: stamp, at: at))
    }

    /// A mouse-up: it waits with its mouse-down, or goes now when that went already. Returns what to send now.
    public mutating func release(_ up: NSEvent) -> [NSEvent] {
        guard let index = held.lastIndex(where: { $0.up == nil && Self.pairs($0.down, up) }) else { return [] }
        if held[index].sent {
            held.remove(at: index)
            return [up]
        }
        held[index].up = up
        return []
    }

    /// `part` went live and its model reads `stamp`: its clicks within the limit whose stamp is the same, in order.
    /// Returns what to send now; the others of `part` are dropped.
    public mutating func partDidGoLive(_ part: String, stamp: String?, at now: ContinuousClock.Instant) -> [NSEvent] {
        var send: [NSEvent] = []
        var kept: [Held] = []
        for var click in held {
            guard click.part == part, !click.sent else {
                kept.append(click)
                continue
            }
            guard click.stamp == stamp, click.at.duration(to: now) <= limit else { continue }
            send.append(click.down)
            if let up = click.up {
                send.append(up)
            } else {
                click.sent = true
                kept.append(click)
            }
        }
        held = kept
        return send
    }

    /// Drops the clicks still waiting for `part` (nil: for every part). A mouse-down that went already keeps its
    /// place, so its mouse-up still follows it.
    public mutating func drop(_ part: String? = nil) {
        held.removeAll { !$0.sent && (part == nil || $0.part == part) }
    }

    /// Whether `up` ends the press `down` began (the same button).
    private static func pairs(_ down: NSEvent, _ up: NSEvent) -> Bool {
        switch (down.type, up.type) {
        case (.leftMouseDown, .leftMouseUp), (.rightMouseDown, .rightMouseUp): true
        case (.otherMouseDown, .otherMouseUp): down.buttonNumber == up.buttonNumber
        default: false
        }
    }
}
