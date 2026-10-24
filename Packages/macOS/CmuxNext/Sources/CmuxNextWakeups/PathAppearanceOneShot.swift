import CmuxNextCompat

/// Resumes one continuation exactly once, from whichever of the file event, the armed-late check
/// and cancellation comes first.
// Lock carve-out (CLAUDE.md concurrency rules): a synchronous one-shot resume guard raced by a
// DispatchSource handler, the arming code and a cancellation handler; an actor would only add hops.
final class PathAppearanceOneShot: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Void, Never>?, fired: Bool, onFire: (@Sendable () -> Void)?)>((nil, false, nil))

    var onFire: (@Sendable () -> Void)? {
        get { state.withLock { $0.onFire } }
        set {
            let fireNow = state.withLock { state -> Bool in
                state.onFire = newValue
                return state.fired
            }
            if fireNow { newValue?() }
        }
    }

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        let fired = state.withLock { state -> Bool in
            if state.fired { return true }
            state.continuation = continuation
            return false
        }
        if fired { continuation.resume() }
    }

    func fire() {
        let (continuation, onFire) = state.withLock { state -> (CheckedContinuation<Void, Never>?, (@Sendable () -> Void)?) in
            guard !state.fired else { return (nil, nil) }
            state.fired = true
            defer { state.continuation = nil }
            return (state.continuation, state.onFire)
        }
        onFire?()
        continuation?.resume()
    }
}
