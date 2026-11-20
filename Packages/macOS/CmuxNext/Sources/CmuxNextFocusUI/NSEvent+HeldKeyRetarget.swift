public import AppKit

public extension NSEvent {
    /// This key event as typed into `window`: a key held in one window and replayed in another (a New Tab key hold).
    ///
    /// - Parameter window: The window the replayed key goes to.
    /// - Returns: The same event when it already names `window`'s number (or AppKit makes no copy), else a copy with
    ///   `window`'s number and every other field of this event.
    func retargeted(to window: NSWindow) -> NSEvent {
        guard windowNumber != window.windowNumber,
              let moved = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifierFlags, timestamp: timestamp,
                                           windowNumber: window.windowNumber, context: nil, characters: characters ?? "",
                                           charactersIgnoringModifiers: charactersIgnoringModifiers ?? "", isARepeat: isARepeat,
                                           keyCode: keyCode) else { return self }
        return moved
    }
}
