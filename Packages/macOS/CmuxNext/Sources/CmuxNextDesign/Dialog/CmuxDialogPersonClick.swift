public import AppKit

/// SECURITY: the Allow of a consent prompt that only the person at this Mac may answer (the join
/// consent sheet, the cookie import panel). As macOS's own privacy prompts take no posted input, the
/// grant comes from the person's own click on Allow, read from the click's events in the prompt
/// window's dispatch (`NSWindow.sendEvent`), never from the button's action: an Accessibility press,
/// a programmatic click, a key, or a click another process posts (CGEventPost: a computer-use agent,
/// a script) reaches no grant. ``isPersonEvent`` decides which events are the person's (the app's
/// strict HID-system check, `PersonInputCheck`); with none set, none is.
///
/// Like Chrome's permission prompts (`InputEventActivationProtector`), a click that begins less than
/// ``activationDelay`` after the prompt shows or moves (``shown(at:)``), or less than that after the
/// person's previous mouse-down (a run of fast clicks), is not taken: a click the person aimed at what was
/// there before the prompt never answers it.
@MainActor
public final class CmuxDialogPersonClick {
    /// Whether an event is the person's own input; with none set, none is.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool = { _ in false }
    /// The event the app is handling now (tests set it).
    public var eventInHand: @MainActor () -> NSEvent? = { NSApp.currentEvent }
    /// How long after the prompt shows, and after the previous mouse-down, a click is not taken.
    public let activationDelay: TimeInterval
    /// When the prompt showed or last moved, in system uptime (`NSEvent.timestamp`).
    private var shownAt: TimeInterval?
    /// The person's previous mouse-down in the prompt (a run of fast clicks is not taken).
    private var lastDown: TimeInterval?
    /// The person's own mouse-down that began the click going on now, with the Allow control enabled when
    /// it came, held until the click ends: AppKit may hand a button the mouse-up in its tracking loop,
    /// inside the mouse-down's dispatch, or (a displayed, non-activating panel) dispatch the mouse-up as
    /// an event of its own (HQ#5121). A click begun while Allow was disabled holds none.
    private var personDown: (event: NSEvent, allow: NSView)?
    /// The last mouse-up that answered Allow: each click answers once.
    private var spentUp: (number: Int, time: TimeInterval)?

    /// - Parameter activationDelay: Chrome's guard against a click aimed at what was there before the
    ///   prompt; 0 takes a click at once (``shown(at:)`` is then not needed).
    public init(activationDelay: TimeInterval = 0) {
        self.activationDelay = activationDelay
    }

    /// The prompt shows, or moves under the pointer, now: a click begun before `uptime` plus
    /// ``activationDelay`` is not taken, and a click held now is dropped.
    public func shown(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        shownAt = uptime
        personDown = nil
    }

    /// Runs `body` (the window's own dispatch of `event`) and returns true when `event` ended the person's
    /// click on `allow()`, the Allow control shown now (nil when none): the caller grants then, once. The
    /// person's mouse-down is kept until its click ends: with the mouse-up's dispatch, or with the
    /// mouse-down's when a button took the mouse-up in its tracking loop there. A drag or pressure change
    /// while the button is held keeps it; any other event clears it.
    public func dispatch(_ event: NSEvent, allow: @MainActor () -> NSControl?, in windowNumber: Int, _ body: () -> Void) -> Bool {
        switch event.type {
        case .leftMouseDown:
            personDown = nil
            if let control = allow(), control.isEnabled, isPersonEvent(event) {
                if settled(event) { personDown = (event: event, allow: control) }
                // Only the person's own: another process's clicks never hold the person's Allow off.
                lastDown = event.timestamp
            }
            body()
            guard let up = eventInHand(), up.type == .leftMouseUp else { return false }
            return endClick(up, allow: allow(), in: windowNumber)
        case .leftMouseDragged, .pressure:
            body()
            return false
        case .leftMouseUp:
            body()
            return endClick(event, allow: allow(), in: windowNumber)
        default:
            personDown = nil
            body()
            return false
        }
    }

    /// Whether a mouse-down came late enough to be aimed at the prompt (Chrome's
    /// `IsPossiblyUnintendedInteraction`): not within ``activationDelay`` of the prompt showing, nor of the
    /// person's previous mouse-down. A prompt with a delay that never said it showed takes none.
    private func settled(_ down: NSEvent) -> Bool {
        guard activationDelay > 0 else { return true }
        guard let shownAt, down.timestamp >= shownAt + activationDelay else { return false }
        return lastDown.map { down.timestamp >= $0 + activationDelay } ?? true
    }

    private func endClick(_ up: NSEvent, allow: NSControl?, in windowNumber: Int) -> Bool {
        defer { personDown = nil }
        guard let allow, allow.isEnabled else { return false }
        return takePersonClick(on: allow, up: up, in: windowNumber)
    }

    /// SECURITY: whether `up` ends a click on `button` that is the person's own, taken once: this holds the
    /// person's mouse-down on the button, taken while that same button was shown and enabled, and `up` is
    /// the person's mouse-up on it, not one taken before. A click another process (or DEBUG automation)
    /// posts, a click begun while Allow was disabled or on a button since rebuilt, a click begun or ended
    /// on anything else, and a click already taken find none.
    public func takePersonClick(on button: NSView, up: NSEvent, in windowNumber: Int) -> Bool {
        guard let held = personDown, held.allow === button, up.type == .leftMouseUp, isPersonEvent(up) else { return false }
        let down = held.event
        guard up.windowNumber == windowNumber, down.windowNumber == windowNumber, up.timestamp >= down.timestamp else { return false }
        let inside = { (event: NSEvent) in button.bounds.contains(button.convert(event.locationInWindow, from: nil)) }
        guard inside(down), inside(up) else { return false }
        if let spent = spentUp, spent.number == up.eventNumber, spent.time == up.timestamp { return false }
        spentUp = (up.eventNumber, up.timestamp)
        return true
    }
}
