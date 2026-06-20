import Foundation

/// The runtime focus-allowance stack for an executing socket control command:
/// the per-command booleans pushed by ``withPolicy(allowsInAppFocusMutations:_:)``
/// while a command runs, read back by the focus-mutating code paths to decide
/// whether they may steal macOS focus.
///
/// This replaces the former process-wide `static` thread-dictionary key on
/// `TerminalController` (`socketCommandFocusAllowanceStackKey` +
/// `currentSocketCommandFocusAllowanceStack`/`setCurrentSocketCommandFocusAllowanceStack`).
/// It is now *injected per-router state*: the line router (one per process today)
/// owns one instance, removing a de-singletonization blocker for retiring the
/// god class.
///
/// Isolation design (why this stays thread-local, not an actor or a plain
/// stored array): a command body runs synchronously on a socket-worker thread
/// and may hop to the main actor mid-body via a `DispatchQueue.main.sync`
/// bridge. The allowance must be visible to whichever thread is currently
/// executing the body and must NOT leak into other concurrently-dispatched
/// commands on other worker threads. A per-thread stack gives exactly that:
/// each thread reads its own frame. Cross-thread propagation across the
/// main-sync hop is explicit (`currentStack()` captures on the worker,
/// ``withStack(_:_:)`` reinstates on main) — the same mechanism the legacy
/// code used. The stack is therefore keyed by both this instance's identity and
/// the current thread, so two routers (if ever constructed) never alias and the
/// state is genuinely instance-scoped rather than process-global.
///
/// `@unchecked Sendable`: the only stored state is the instance's identity-
/// derived `Thread.threadDictionary` key (an immutable `String`). All mutable
/// stack state lives in the per-thread dictionary, which is inherently
/// thread-confined, so there is no shared mutable state to race.
public final class ControlSocketFocusAllowanceStack: @unchecked Sendable {
    private let storageKey: String

    /// Creates an empty allowance stack with its own thread-local storage slot.
    public init() {
        storageKey = "cmux.socketCommandFocusAllowanceStack.\(UUID().uuidString)"
    }

    /// The current thread's allowance stack (empty when no command is active on
    /// this thread).
    public func currentStack() -> [Bool] {
        Thread.current.threadDictionary[storageKey] as? [Bool] ?? []
    }

    /// Replaces the current thread's allowance stack. An empty stack removes the
    /// dictionary entry so an idle thread leaves no residue (matches legacy).
    public func setCurrentStack(_ stack: [Bool]) {
        if stack.isEmpty {
            Thread.current.threadDictionary.removeObject(forKey: storageKey)
        } else {
            Thread.current.threadDictionary[storageKey] = stack
        }
    }

    /// True when any command's allowance frame is active on the current thread.
    /// (The socket command is in flight, so app activation must be suppressed.)
    public var isCommandActive: Bool {
        !currentStack().isEmpty
    }

    /// The top frame's allowance: whether the innermost active command may
    /// mutate in-app focus. False when no command is active.
    public var topAllowsFocusMutation: Bool {
        currentStack().last ?? false
    }

    /// Pushes one command's allowance for the duration of `body`, popping it on
    /// exit. Mirrors the legacy `withSocketCommandPolicy` push/defer-pop.
    @discardableResult
    public func withPolicy<T>(allowsInAppFocusMutations: Bool, _ body: () -> T) -> T {
        var stack = currentStack()
        stack.append(allowsInAppFocusMutations)
        setCurrentStack(stack)
        defer {
            var stack = currentStack()
            if !stack.isEmpty {
                _ = stack.popLast()
            }
            setCurrentStack(stack)
        }
        return body()
    }

    /// Runs `body` with the current thread's stack temporarily replaced by
    /// `stack`, restoring the previous stack on exit. Used to propagate the
    /// worker thread's allowance across a hop to the main actor. Mirrors the
    /// legacy `withSocketCommandPolicyStack`.
    @discardableResult
    public func withStack<T>(_ stack: [Bool], _ body: () -> T) -> T {
        let previous = currentStack()
        setCurrentStack(stack)
        defer { setCurrentStack(previous) }
        return body()
    }
}
