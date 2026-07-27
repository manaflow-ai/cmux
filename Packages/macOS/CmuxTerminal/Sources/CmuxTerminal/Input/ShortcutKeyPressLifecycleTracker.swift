/// Preserves the owner of a physical key across every shortcut dispatch entrypoint.
///
/// AppKit can present one key-down to a local event monitor and then to one or
/// more key-equivalent fallbacks. Those callbacks share an event identity and
/// may upgrade an initially unhandled press to shortcut ownership. Later repeat
/// events cannot change the owner selected during the original press.
public struct ShortcutKeyPressLifecycleTracker: Sendable {
    private var shortcutOwnedKeyCodes: Set<UInt16> = []
    private var lastEventIdentities: [UInt16: ShortcutKeyEventIdentity] = [:]

    /// Creates an empty shortcut key lifecycle tracker.
    public init() {}

    /// Dispatches one key-down if its physical lifecycle permits shortcut routing.
    ///
    /// A non-repeat may visit multiple AppKit entrypoints with the same event
    /// identity. A later entrypoint can claim that event if an earlier one did
    /// not handle it. Repeats retain the original press owner, and a shortcut-
    /// owned repeat invokes the dispatcher at most once per event identity.
    public mutating func shortcutConsumesKeyDown(
        keyCode: UInt16,
        eventIdentity: ShortcutKeyEventIdentity,
        isRepeat: Bool,
        dispatchShortcut: () -> Bool
    ) -> Bool {
        if isRepeat, lastEventIdentities[keyCode] == nil {
            return false
        }

        if let lastEventIdentity = lastEventIdentities[keyCode] {
            if isRepeat {
                guard shortcutOwnedKeyCodes.contains(keyCode) else {
                    return false
                }
                guard lastEventIdentity != eventIdentity else {
                    return true
                }

                lastEventIdentities[keyCode] = eventIdentity
                _ = dispatchShortcut()
                return true
            }

            if lastEventIdentity == eventIdentity {
                if shortcutOwnedKeyCodes.contains(keyCode) {
                    return true
                }

                let handled = dispatchShortcut()
                if handled {
                    shortcutOwnedKeyCodes.insert(keyCode)
                }
                return handled
            }
        }

        let handled = dispatchShortcut()
        lastEventIdentities[keyCode] = eventIdentity
        if handled {
            shortcutOwnedKeyCodes.insert(keyCode)
        } else {
            shortcutOwnedKeyCodes.remove(keyCode)
        }
        return handled
    }

    /// Clears a completed lifecycle and returns whether the shortcut owned it.
    public mutating func shortcutConsumesKeyUp(keyCode: UInt16) -> Bool {
        lastEventIdentities.removeValue(forKey: keyCode)
        return shortcutOwnedKeyCodes.remove(keyCode) != nil
    }

    /// Clears every lifecycle after the application loses its event stream.
    public mutating func reset() {
        shortcutOwnedKeyCodes.removeAll(keepingCapacity: true)
        lastEventIdentities.removeAll(keepingCapacity: true)
    }
}
