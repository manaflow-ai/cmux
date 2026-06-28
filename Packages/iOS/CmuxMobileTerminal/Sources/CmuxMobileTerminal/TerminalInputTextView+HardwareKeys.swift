import Foundation
import UIKit

// MARK: - Hardware-keyboard capture (pressesBegan — below the text system)
//
// The direct-terminal first responder is this `UIKeyInput`/`UITextInput`
// proxy. With UIKit's text-editing layer focused on the zero-width virtual
// document, arrows/Tab/Ctrl-nav are consumed as no-op caret edits BEFORE
// `keyCommands` (or `wantsPriorityOverSystemBehavior`) can fire. Capturing
// at `pressesBegan` runs below the text system, so special keys and
// Control/Option chords reach the terminal; everything else falls through to
// `super` so normal typing/IME/dictation still routes via `insertText`. The
// capture decision, byte encoding, and timer-driven hold-to-repeat all live
// in the dedicated `TerminalHardwareKeyCapture` (stored on the view); the
// overrides below are thin adapters that hand UIKit's press batches to it and
// forward the remainder to `super`.
extension TerminalInputTextView {
    /// The hardware-key command table for this documentless responder.
    ///
    /// Hardware keys are captured exclusively by ``pressesBegan(_:with:)`` (which
    /// runs below the text-editing layer), so there is no nav/Control/Shift-Arrow
    /// `UIKeyCommand` table here — a second `UIKeyCommand` handler racing
    /// `pressesBegan` for the same chords was the source of the inconsistent
    /// ("janky") modifier behavior. The lone surviving command is Cmd+V:
    /// `shouldConsume` deliberately lets plain Command fall through, so paste
    /// reaches this routing (a bare `UIView` does not inherit `UITextView`'s
    /// Cmd+V). Claim priority so the text-input layer cannot eat it first.
    override var keyCommands: [UIKeyCommand]? {
        TerminalInputDebugLog.log("proxy.keyCommands.getter")
        guard markedText == nil else { return nil }
        let pasteCommand = UIKeyCommand(input: "v", modifierFlags: [.command], action: #selector(paste(_:)))
        pasteCommand.wantsPriorityOverSystemBehavior = true
        return [pasteCommand]
    }

    /// Logs the first-responder acquisition of the input proxy and defers to
    /// `super`; capture wiring lives in ``pressesBegan(_:with:)``.
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        TerminalInputDebugLog.log("proxy.becomeFR cls=\(String(describing: type(of: self))) ok=\(ok)")
        return ok
    }

    /// Cancels every in-flight hold-to-repeat before yielding first responder.
    ///
    /// A hardware key held while focus leaves this proxy never delivers its
    /// `pressesEnded`, so reset the capture state (which also drops the
    /// captured-press set whose matching ends will never arrive) before
    /// resigning.
    override func resignFirstResponder() -> Bool {
        hardwareKeyCapture.reset()
        return super.resignFirstResponder()
    }

    /// Routes a hardware key-press batch through ``hardwareKeyCapture``; any
    /// presses it does not consume are forwarded to `super` so normal
    /// typing/IME/dictation still flows through the text system.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = hardwareKeyCapture.pressesBegan(presses)
        if !forwarded.isEmpty { super.pressesBegan(forwarded, with: event) }
    }

    /// Ends hold-to-repeat for the captured presses and forwards the remainder to
    /// `super`.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = hardwareKeyCapture.pressesEnded(presses)
        if !forwarded.isEmpty { super.pressesEnded(forwarded, with: event) }
    }

    /// Cancels hold-to-repeat for the captured presses and forwards the remainder
    /// to `super`.
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = hardwareKeyCapture.pressesCancelled(presses)
        if !forwarded.isEmpty { super.pressesCancelled(forwarded, with: event) }
    }

    /// Restores standard system paste on this documentless responder.
    ///
    /// As a `UITextView` the view inherited `paste(_:)`/`canPerformAction(_:)`;
    /// as a bare `UIView` it must re-expose them so hardware Cmd+V and the
    /// edit-menu Paste keep working. Only paste is advertised — copy/cut/select
    /// are meaningless on a proxy that holds no document, so they stay disabled
    /// rather than surfacing a broken edit menu.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
        }
        return false
    }

    /// System Paste (Cmd+V or the edit-menu item) routed through the same
    /// clipboard handling as the toolbar Paste button: an image goes to the Mac
    /// as `terminal.paste_image`, text rides the normal input sink.
    override func paste(_ sender: Any?) {
        handlePasteAction()
    }
}
