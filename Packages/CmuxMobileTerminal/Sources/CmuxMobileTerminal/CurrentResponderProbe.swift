#if canImport(UIKit)
import UIKit

/// Resolves the current `UIResponder` first responder for DEBUG input
/// instrumentation.
///
/// UIKit exposes no public "who is first responder" API. The standard technique
/// is to send an action to the `nil` target: UIKit walks the responder chain
/// from the current first responder and invokes the first responder that
/// implements the selector. By defining the capture selector as a
/// ``UIResponder`` extension, *every* responder implements it, so the action
/// lands on the actual first responder, which records `self`.
///
/// This is a DEBUG-only diagnostic aid for the hold-backspace + dictation
/// evidence round; it never drives behavior. `@MainActor` because it touches
/// `UIApplication.shared.sendAction` on the main thread.
@MainActor
enum CurrentResponderProbe {
    /// Returns the current first responder, or `nil` if there is none.
    static func current() -> UIResponder? {
        CurrentResponderCapture.captured = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.cmuxDiagnosticCaptureFirstResponder(_:)),
            to: nil,
            from: nil,
            for: nil
        )
        let captured = CurrentResponderCapture.captured
        CurrentResponderCapture.captured = nil
        return captured
    }
}

/// Holds the responder captured during a ``CurrentResponderProbe/current()``
/// probe.
///
/// The `sendAction(to: nil)` walk is synchronous and main-thread-only, and the
/// captured pointer is read immediately after on the same call, so the single
/// stored slot never races. `nonisolated(unsafe)` is acceptable here: writes and
/// reads are confined to the main actor's synchronous `sendAction` round-trip in
/// ``CurrentResponderProbe/current()``, and this is DEBUG-only diagnostic
/// scaffolding.
private enum CurrentResponderCapture {
    nonisolated(unsafe) static weak var captured: UIResponder?
}

private extension UIResponder {
    /// Records `self` as the captured first responder. Invoked by UIKit's
    /// responder-chain walk during ``CurrentResponderProbe/current()``; only the
    /// actual first responder receives it.
    @objc func cmuxDiagnosticCaptureFirstResponder(_ sender: Any?) {
        CurrentResponderCapture.captured = self
    }
}
#endif
