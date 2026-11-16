public import AppKit

/// A held New Tab key (decision 2026-11-16): while the system repeats the key, each repeat makes a tab with no
/// page, and the page of the selected tab is made when the hold ends.
///
/// The hold begins when a new tab with no page is made in the dispatch of a key-down that the system repeats
/// (``begin(at:atEnd:)``). The repeat flag is the event's own fact. The first key-down of a press is no repeat: it
/// begins no hold, so a single key is not delayed.
///
/// The hold ends at an event of the system. It has no clock and no timer:
///
/// - the key-up of the held key;
/// - a flags event after which a modifier of the held key-down is no longer down (Command up);
/// - a key-down that is no repeat, or a repeat of another key;
/// - the app is no longer the active app (the App calls ``end()``).
///
/// ``InputDispatchContext`` owns the one hold and feeds it each event that it dispatches:
///
/// ```swift
/// inputDispatch.newTabHold.begin(at: inputDispatch.event) { showTheSelectedTab() }
/// ```
///
/// A window that is no longer key ends nothing: the app still gets each key event while it is active.
@MainActor
public final class NewTabKeyHold {
    /// The modifiers that a shortcut can hold down.
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// The held key: its key code and the shortcut modifiers of its key-down. Nil with no hold.
    private var held: (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)?
    /// What the end of this hold runs: the last opening's.
    private var atEnd: (@MainActor () -> Void)?

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

    /// A new tab with no page was made in `event`'s dispatch. When `event` is a repeat, the hold begins, or goes
    /// on with this opening's `atEnd` in place of the one before.
    ///
    /// - Parameters:
    ///   - event: The event in dispatch, nil with none.
    ///   - atEnd: Runs once, at the hold's end: it shows the tab that waited.
    /// - Returns: Whether the hold took this opening. False: `event` is no repeat, and `atEnd` never runs.
    @discardableResult
    public func begin(at event: NSEvent?, atEnd: @escaping @MainActor () -> Void) -> Bool {
        guard let event, Self.isRepeat(event) else { return false }
        held = (event.keyCode, event.modifierFlags.intersection(Self.shortcutModifiers))
        self.atEnd = atEnd
        return true
    }

    /// An event that the application got, before its dispatch: ends the hold when it is one of the hold's ends.
    ///
    /// - Parameter event: The event.
    public func note(_ event: NSEvent) {
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

    /// Ends the hold and runs its end. Nothing with no hold.
    public func end() {
        guard held != nil else { return }
        held = nil
        let run = atEnd
        atEnd = nil
        run?()
    }
}
