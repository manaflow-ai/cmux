public import Foundation

/// The key whose binding runs now: the App's key router runs each binding a key-down resolved to inside
/// ``handling(input:_:)``, so a tab switch (`debug.tab_switch`) or a pane focus move (`switch.pane_focus`) the
/// binding begins takes that key's `NSEvent.timestamp` as its input stage. A synthetic key (`debug.key`, a
/// replayed held key) never becomes `NSApp.currentEvent`, so the scope, not AppKit, says which key it is.
///
/// The router owns the one instance; each window's focus coordinator and each pane controller read it through
/// their window and services (``InputDispatchContext`` is the same kind of seam for the event being dispatched).
@MainActor
public final class KeyInputScope {
    /// The timestamp of the key whose binding runs now; nil outside a binding run.
    public private(set) var timestamp: TimeInterval?

    public init() {}

    /// Runs `body` with `input` (an `NSEvent.timestamp`) as ``timestamp``; a nested run sees its own key.
    ///
    /// - Parameters:
    ///   - input: The key's `NSEvent.timestamp`.
    ///   - body: The binding run.
    public func handling(input: TimeInterval, _ body: () -> Void) {
        let previous = timestamp
        timestamp = input
        defer { timestamp = previous }
        body()
    }
}
