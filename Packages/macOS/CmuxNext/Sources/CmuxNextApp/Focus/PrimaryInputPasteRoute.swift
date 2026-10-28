import AppKit
import CmuxNextTerminal

/// Where a paste command goes when the focused surface has a primary input
/// (Home's message box) and none of its text inputs has the keyboard.
///
/// The app resolves every nil-targeted action through this route
/// (`CmuxApplication.target(forAction:to:from:)`), so one rule covers each way
/// a paste arrives: Cmd+V and its variants as menu key equivalents, a click on
/// Edit > Paste, and a dictation app's synthetic Cmd+V (Wispr Flow pastes its
/// text that way). The paste goes to the primary input when AppKit's own
/// target is nothing, the window or app, or a read-only text view (a bubble
/// after a click, whose Paste is disabled and would beep). A text input the
/// person can type in, a terminal, a web view and Home's own forwarding views
/// keep the paste.
@MainActor
struct PrimaryInputPasteRoute {
    /// The paste commands that move; every other action keeps AppKit's target.
    static let actions: Set<Selector> = [
        #selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)),
        #selector(NSTextView.pasteAsRichText(_:)),
    ]

    /// The object that takes `action` instead of `found`, or nil to keep `found`.
    /// - Parameters:
    ///   - action: The command being sent or validated.
    ///   - found: AppKit's responder-chain target for it (nil when none).
    ///   - window: The key window.
    ///   - input: The focused pane's primary input in `window`, if any.
    func target(for action: Selector, found: AnyObject?, in window: NSWindow?, input: (any PrimaryInputTarget)?) -> AnyObject? {
        guard Self.actions.contains(action), let window, let input, let view = input.primaryInputView,
              view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let responder = window.firstResponder
        if responder === view || responder is TerminalSurfaceView || responder?.ownsTypedText == true { return nil }
        guard Self.yields(found) else { return nil }
        return PrimaryInputPasteForwarder(input: view)
    }

    /// Whether AppKit's target gives the paste up: none, a non-view (the
    /// window, the app, a delegate), or a text view that takes no typing.
    private static func yields(_ found: AnyObject?) -> Bool {
        guard let found else { return true }
        if let text = found as? NSText { return !text.isEditable }
        return !(found is NSView)
    }
}
