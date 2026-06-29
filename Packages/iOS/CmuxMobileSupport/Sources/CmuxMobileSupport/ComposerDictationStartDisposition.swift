/// Whether an asynchronous engine-ready callback still applies to the current
/// dictation start attempt, or has been superseded.
///
/// The audio engine activates OFF the main actor (issue #6284), so its "ready"
/// callback lands ~100-300ms after the mic tap. In that window the user can
/// double-tap the mic, send, or navigate away — abandoning the start. Each start
/// stamps a monotonic token and every abandon bumps it, so the callback can tell
/// whether it is still the current attempt. Factored out as a pure value (and
/// ``ComposerDictationState/startDisposition(callbackToken:currentToken:)``) so the
/// supersession rule is host-testable without the Speech / AVFoundation stack.
///
/// `internal` (unlike the cross-module ``ComposerDictationState``): only the
/// in-module controller consumes it; tests reach it via `@testable import`.
enum ComposerDictationStartDisposition: Equatable {
    /// The engine came up for the CURRENT attempt: create the recognition task
    /// and move to ``ComposerDictationState/listening``.
    case apply
    /// A newer start, a cancel, or a teardown superseded this attempt: discard the
    /// result. The superseding path already enqueued the engine teardown (ordered
    /// before any later start on the owner's serial queue), so the callback must
    /// NOT enqueue another stop — doing so could race ahead and tear down a
    /// subsequent legitimate start.
    case discardStale
}

extension ComposerDictationState {
    /// Decide whether an engine-ready callback applies for this state (see
    /// ``ComposerDictationStartDisposition``).
    ///
    /// The callback applies only when its captured `callbackToken` still matches the
    /// controller's `currentToken` AND this state is still
    /// ``ComposerDictationState/requestingPermission`` (it has not already moved to
    /// ``ComposerDictationState/listening``, ``ComposerDictationState/idle``,
    /// ``ComposerDictationState/stopping``, or ``ComposerDictationState/unavailable``).
    /// The state check is belt-and-suspenders next to the token: any path that leaves
    /// `requestingPermission` while an engine start is in flight bumps the token too.
    ///
    /// - Parameters:
    ///   - callbackToken: The start token captured when this attempt kicked off the
    ///     off-main engine activation.
    ///   - currentToken: The controller's current start token at callback time.
    func startDisposition(callbackToken: Int, currentToken: Int) -> ComposerDictationStartDisposition {
        guard callbackToken == currentToken, self == .requestingPermission else {
            return .discardStale
        }
        return .apply
    }
}
