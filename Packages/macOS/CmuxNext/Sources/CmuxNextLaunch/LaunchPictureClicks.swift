public import AppKit

/// The clicks ``LaunchPictureInput`` holds while a part of the window is still its picture (p08-startup-061), in
/// the order pressed: which to send again when the part's region goes live, and which to drop.
///
/// A held click is its mouse-down and, once it came, its mouse-up. When its part leaves (at its region's first content,
/// or at the picture's bound: the live root shows there then) and the model the part shows reads the same as at the
/// press, both go again in order; a mouse-up that comes after its mouse-down went follows it at once. A held click is
/// dropped only when the point means something else now (another workspace shows, the window changed size).
///
/// ```swift
/// var clicks = LaunchPictureClicks()
/// clicks.press(down, part: "pane", stamp: "ws-1", at: now)
/// _ = clicks.release(up)                                      // [] (it waits with its press)
/// clicks.partDidGoLive("pane", stamp: "ws-1", at: now).send   // [down, up]
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

    public init() {}

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

    /// What a part's leaving did with its held clicks.
    public struct Outcome {
        /// The events to send now, in order.
        public var send: [NSEvent] = []
        /// Clicks sent (their press).
        public var delivered = 0
        /// Clicks dropped: what the window shows changed since the press.
        public var dropped = 0
        /// The longest a sent click waited.
        public var longestWait: Duration = .zero
    }

    /// `part` left (its region went live, or the bound took it down: the live root shows there either way) and its
    /// model reads `stamp`: its clicks whose stamp is the same go, in order, however long they waited (a click on an
    /// unchanged window means what it meant). The others of `part` are dropped.
    public mutating func partDidGoLive(_ part: String, stamp: String?, at now: ContinuousClock.Instant) -> Outcome {
        var outcome = Outcome()
        var kept: [Held] = []
        for var click in held {
            guard click.part == part, !click.sent else {
                kept.append(click)
                continue
            }
            guard click.stamp == stamp else {
                outcome.dropped += 1
                continue
            }
            outcome.delivered += 1
            outcome.longestWait = max(outcome.longestWait, click.at.duration(to: now))
            outcome.send.append(click.down)
            if let up = click.up {
                outcome.send.append(up)
            } else {
                click.sent = true
                kept.append(click)
            }
        }
        held = kept
        return outcome
    }

    /// The parts of the clicks still waiting, in press order (each once).
    public var waitingParts: [String] {
        var seen = Set<String>()
        return held.filter { !$0.sent }.map(\.part).filter { seen.insert($0).inserted }
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
