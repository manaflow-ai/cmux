import AppKit

// AppKit input into the journal. `CmuxApplication.sendEvent` calls
// `record(_:)` for every event before anything (including the app-wide key
// router) can consume it, so intercepted chords are journaled too.
extension InputJournal {
    /// Records a keyboard or mouse event dispatched to this process.
    /// Mouse moves are not recorded (hover carries no focus).
    func record(_ event: NSEvent) {
        guard isEnabled else { return }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            let phase: InputJournalEntry.KeyPhase = event.type == .keyDown ? .down : event.type == .keyUp ? .up : .flags
            let key = InputJournalEntry.Key(
                phase: phase,
                keyCode: event.keyCode,
                modifiers: .init(event.modifierFlags),
                isRepeat: phase == .down && event.isARepeat,
                characters: phase != .flags && recordsCharacters ? event.charactersIgnoringModifiers : nil
            )
            append(window: Self.windowID(of: event.window), .key(key))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            recordMouse(event, phase: .down)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            recordMouse(event, phase: .up)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            recordMouse(event, phase: .drag)
        case .scrollWheel:
            recordMouse(event, phase: .scroll)
        default:
            break
        }
    }

    private func recordMouse(_ event: NSEvent, phase: InputJournalEntry.MousePhase) {
        let window = event.window
        let owner = Self.cmuxWindow(of: window)
        let point = Self.topLeftPoint(event.locationInWindow, in: window, relativeTo: owner)
        appendMouse(window: Self.windowID(of: owner), InputJournalEntry.Mouse(
            phase: phase,
            button: event.buttonNumber > 2 ? 2 : event.buttonNumber,
            x: point.x, y: point.y,
            clickCount: phase == .down || phase == .up ? event.clickCount : 0,
            modifiers: .init(event.modifierFlags),
            dx: phase == .scroll ? event.scrollingDeltaX : 0,
            dy: phase == .scroll ? event.scrollingDeltaY : 0
        ))
    }

    /// The cmux window an event window belongs to: itself, or the parent of
    /// a Chromium page window. Panels are not cmux windows.
    static func cmuxWindow(of window: NSWindow?) -> NSWindow? {
        guard let window else { return nil }
        if window.windowController is WindowController { return window }
        if let parent = window.parent, parent.windowController is WindowController, !(window is NSPanel) { return parent }
        return nil
    }

    static func windowID(of window: NSWindow?) -> String? {
        (cmuxWindow(of: window)?.windowController as? WindowController)?.state.id
    }

    /// `location` (bottom-left, in `window`) as top-left points in `owner`
    /// (the coordinates `debug.mouse` takes).
    static func topLeftPoint(_ location: NSPoint, in window: NSWindow?, relativeTo owner: NSWindow?) -> NSPoint {
        guard let window else { return location }
        let target = owner ?? window
        let local = window === target ? location : target.convertPoint(fromScreen: window.convertPoint(toScreen: location))
        let height = target.contentView?.bounds.height ?? target.frame.height
        return NSPoint(x: local.x.rounded(), y: (height - local.y).rounded())
    }
}

extension InputJournalEntry.ModifierClasses {
    init(_ flags: NSEvent.ModifierFlags) {
        var classes: Self = []
        if flags.contains(.command) { classes.insert(.command) }
        if flags.contains(.shift) { classes.insert(.shift) }
        if flags.contains(.option) { classes.insert(.option) }
        if flags.contains(.control) { classes.insert(.control) }
        if flags.contains(.function) { classes.insert(.function) }
        if flags.contains(.capsLock) { classes.insert(.capsLock) }
        self = classes
    }

    var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        if contains(.function) { flags.insert(.function) }
        if contains(.capsLock) { flags.insert(.capsLock) }
        return flags
    }
}
