public import AppKit

/// A held New Tab key (decision 2026-11-16): while the system repeats the key, each repeat makes a tab with no
/// page, and the page of the selected tab is made when the hold ends.
///
/// The hold begins when a new tab with no page is made in the dispatch of a key-down that the system repeats
/// (``begin(at:for:atEnd:)``). The repeat flag is the event's own fact. The first key-down of a press is no repeat:
/// it begins no hold, so a single key is not delayed.
///
/// The hold ends at an event of the system. It has no clock and no timer:
///
/// - the key-up of the held key;
/// - a flags event after which a modifier of the held key-down is no longer down (Command up);
/// - a key-down that is no repeat, or a repeat of another key;
/// - the app is no longer the active app (the App calls ``resigned()``).
///
/// A repeat begins a hold only when one of these events can still come after it. The app can get a repeat again
/// later than the system made it (a window keeps key-downs while a creation has no answer, and sends them again):
///
/// - a repeat that is older than the newest key-up, flags event or key-down with no repeat flag, of any key,
///   begins no hold: the event that ends its key's hold can be in the past;
/// - after the app resigned, a repeat that is no newer than the newest event that the app got before begins no
///   hold: its key-up went to another app.
///
/// The times are the events' own (`NSEvent.timestamp`); the hold reads no clock. With events in the system's order
/// each repeat is newer than each event before it, and none is refused.
///
/// The hold is the app's, one for all panes: while it is on, no pane makes the page of a New Tab page
/// (``holds(_:atEnd:)``). Each pane that waits has its own end, and the hold's end runs each of them once.
///
/// ``InputDispatchContext`` owns the one hold and feeds it each event that it dispatches:
///
/// ```swift
/// inputDispatch.newTabHold.begin(at: inputDispatch.event, for: pane) { showTheSelectedTab() }
/// ```
///
/// A window that is no longer key ends nothing: the app still gets each key event while it is active.
@MainActor
public final class NewTabKeyHold {
    /// The modifiers that a shortcut can hold down.
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// The held key: its key code and the shortcut modifiers of its key-down. Nil with no hold.
    private var held: (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)?
    /// What the end of this hold runs: one end for each owner that waits (its last), in the order of each owner's
    /// first wait.
    private var ends: [(owner: ObjectIdentifier, run: @MainActor () -> Void)] = []
    /// A repeat with a time before this begins no hold: the newest time of an event that can end a hold, and after
    /// a resign the next time above each event that the app got.
    private var notBefore: TimeInterval = 0
    /// The newest time of an event that the app got.
    private var newestEvent: TimeInterval = 0

    /// A hold that is not on.
    public init() {}

    /// Whether a hold is on: a new tab with no page waits for the key's end.
    public var isOn: Bool { held != nil }

    /// Whether `event` is a key-down that the system repeats (a held key). Nil is no repeat.
    ///
    /// - Parameter event: The event in dispatch.
    /// - Returns: True for a key-down with the repeat flag.
    public static func isRepeat(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    /// A new tab with no page was made in `event`'s dispatch. When `event` is a repeat that an end can still come
    /// after, the hold begins, or goes on, and `owner` waits for its end with this opening's `atEnd` in place of
    /// its one before.
    ///
    /// - Parameters:
    ///   - event: The event in dispatch, nil with none.
    ///   - owner: What waits (a pane): it has one end.
    ///   - atEnd: Runs once, at the hold's end: it shows the tab that waited.
    /// - Returns: Whether the hold took this opening. False: `event` is no repeat, or it is older than an event
    ///   that can have ended its hold; `atEnd` never runs.
    @discardableResult
    public func begin(at event: NSEvent?, for owner: AnyObject, atEnd: @escaping @MainActor () -> Void) -> Bool {
        guard let event, Self.isRepeat(event), event.timestamp >= notBefore else { return false }
        held = (event.keyCode, event.modifierFlags.intersection(Self.shortcutModifiers))
        wait(owner, atEnd)
        return true
    }

    /// Whether `owner` must wait for the hold's end. When a hold is on, `owner` waits with `atEnd` in place of its
    /// end before: an owner that began no hold (its tab was made with no key) is shown at the end too.
    ///
    /// - Parameters:
    ///   - owner: What asks (a pane): it has one end.
    ///   - atEnd: Runs once, at the hold's end. Never with no hold.
    /// - Returns: Whether a hold is on.
    public func holds(_ owner: AnyObject, atEnd: @escaping @MainActor () -> Void) -> Bool {
        guard isOn else { return false }
        wait(owner, atEnd)
        return true
    }

    /// An event that the application got, before its dispatch: ends the hold when it is one of the hold's ends.
    ///
    /// - Parameter event: The event.
    public func note(_ event: NSEvent) {
        newestEvent = max(newestEvent, event.timestamp)
        switch event.type {
        case .keyUp, .flagsChanged:
            notBefore = max(notBefore, event.timestamp)
        case .keyDown:
            if !event.isARepeat { notBefore = max(notBefore, event.timestamp) }
        default:
            break
        }
        guard let held else { return }
        switch event.type {
        case .keyUp:
            if event.keyCode == held.keyCode { end() }
        case .flagsChanged:
            if !event.modifierFlags.isSuperset(of: held.modifiers) { end() }
        case .keyDown:
            if !event.isARepeat || event.keyCode != held.keyCode { end() }
        default:
            break
        }
    }

    /// Ends the hold and runs each owner's end once. Nothing with no hold.
    public func end() {
        guard held != nil else { return }
        held = nil
        let runs = ends
        ends = []
        for each in runs { each.run() }
    }

    /// The app is no longer the active app: no key-up comes to it. Ends the hold, and a repeat that the app got
    /// before begins no hold when it runs again.
    public func resigned() {
        notBefore = max(notBefore, newestEvent.nextUp)
        end()
    }

    private func wait(_ owner: AnyObject, _ run: @escaping @MainActor () -> Void) {
        let id = ObjectIdentifier(owner)
        if let index = ends.firstIndex(where: { $0.owner == id }) {
            ends[index].run = run
        } else {
            ends.append((owner: id, run: run))
        }
    }
}
