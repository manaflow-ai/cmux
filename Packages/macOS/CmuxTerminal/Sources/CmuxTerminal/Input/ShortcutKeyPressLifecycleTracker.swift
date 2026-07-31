/// Preserves the owner of a physical key across every shortcut dispatch entrypoint.
///
/// AppKit can present one key-down to a local event monitor and then to one or
/// more key-equivalent fallbacks. Those callbacks share an event identity and
/// may upgrade an initially unhandled press to shortcut ownership. Later repeat
/// events cannot change the owner selected during the original press.
public struct ShortcutKeyPressLifecycleTracker: Sendable {
    /// Describes what the caller should do after admitting a key-down.
    public enum KeyDownDecision: Equatable, Sendable {
        /// Leave the event with AppKit or the current responder.
        case passThrough
        /// Consume the event without dispatching the shortcut again.
        case consume
        /// Dispatch the shortcut after the tracker's mutable access has ended.
        case dispatch(KeyDownDispatch)
    }

    /// Identifies one admitted shortcut dispatch for later reconciliation.
    public struct KeyDownDispatch: Equatable, Sendable {
        fileprivate enum CompletionBehavior: Equatable, Sendable {
            case claimIfHandled
            case consumeRegardless
        }

        fileprivate let keyCode: UInt16
        fileprivate let generation: UInt64
        fileprivate let completionBehavior: CompletionBehavior
    }

    private enum Owner: Equatable, Sendable {
        case responder
        case pendingShortcut
        case shortcut
    }

    private struct Lifecycle: Sendable {
        var eventIdentity: ShortcutKeyEventIdentity
        var owner: Owner
        let generation: UInt64
    }

    private var lifecyclesByKeyCode: [UInt16: Lifecycle] = [:]
    private var nextGeneration: UInt64 = 0

    /// Creates an empty shortcut key lifecycle tracker.
    public init() {}

    /// Admits one key-down and records any provisional shortcut ownership.
    ///
    /// A non-repeat may visit multiple AppKit entrypoints with the same event
    /// identity. A later entrypoint can claim that event if an earlier one did
    /// not handle it. Repeats retain the original press owner, and a shortcut-
    /// owned repeat requests dispatch at most once per event identity.
    ///
    /// The caller must execute a returned dispatch only after this mutating
    /// method returns, then pass its result to `completeKeyDownDispatch`.
    public mutating func prepareKeyDown(
        keyCode: UInt16,
        eventIdentity: ShortcutKeyEventIdentity,
        isRepeat: Bool
    ) -> KeyDownDecision {
        if isRepeat {
            guard let lifecycle = lifecyclesByKeyCode[keyCode] else {
                return .passThrough
            }

            switch lifecycle.owner {
            case .responder:
                return .passThrough
            case .pendingShortcut:
                return .consume
            case .shortcut:
                guard lifecycle.eventIdentity != eventIdentity else {
                    return .consume
                }

                let generation = takeGeneration()
                lifecyclesByKeyCode[keyCode] = Lifecycle(
                    eventIdentity: eventIdentity,
                    owner: .shortcut,
                    generation: generation
                )
                return .dispatch(KeyDownDispatch(
                    keyCode: keyCode,
                    generation: generation,
                    completionBehavior: .consumeRegardless
                ))
            }
        }

        if let lifecycle = lifecyclesByKeyCode[keyCode],
           lifecycle.eventIdentity == eventIdentity {
            switch lifecycle.owner {
            case .responder:
                return prepareConditionalDispatch(
                    keyCode: keyCode,
                    eventIdentity: eventIdentity
                )
            case .pendingShortcut, .shortcut:
                return .consume
            }
        }

        return prepareConditionalDispatch(
            keyCode: keyCode,
            eventIdentity: eventIdentity
        )
    }

    /// Reconciles a dispatched action without reviving a lifecycle that ended
    /// or was replaced while the action ran.
    public mutating func completeKeyDownDispatch(
        _ dispatch: KeyDownDispatch,
        handled: Bool
    ) -> Bool {
        switch dispatch.completionBehavior {
        case .consumeRegardless:
            return true
        case .claimIfHandled:
            if var lifecycle = lifecyclesByKeyCode[dispatch.keyCode],
               lifecycle.generation == dispatch.generation,
               lifecycle.owner == .pendingShortcut {
                lifecycle.owner = handled ? .shortcut : .responder
                lifecyclesByKeyCode[dispatch.keyCode] = lifecycle
            }
            return handled
        }
    }

    /// Clears a completed lifecycle and returns whether the shortcut owned it.
    public mutating func shortcutConsumesKeyUp(keyCode: UInt16) -> Bool {
        guard let lifecycle = lifecyclesByKeyCode.removeValue(forKey: keyCode) else {
            return false
        }
        return lifecycle.owner != .responder
    }

    /// Clears every lifecycle after the application loses its event stream.
    public mutating func reset() {
        lifecyclesByKeyCode.removeAll(keepingCapacity: true)
    }

    private mutating func prepareConditionalDispatch(
        keyCode: UInt16,
        eventIdentity: ShortcutKeyEventIdentity
    ) -> KeyDownDecision {
        let generation = takeGeneration()
        lifecyclesByKeyCode[keyCode] = Lifecycle(
            eventIdentity: eventIdentity,
            owner: .pendingShortcut,
            generation: generation
        )
        return .dispatch(KeyDownDispatch(
            keyCode: keyCode,
            generation: generation,
            completionBehavior: .claimIfHandled
        ))
    }

    private mutating func takeGeneration() -> UInt64 {
        nextGeneration &+= 1
        return nextGeneration
    }
}
