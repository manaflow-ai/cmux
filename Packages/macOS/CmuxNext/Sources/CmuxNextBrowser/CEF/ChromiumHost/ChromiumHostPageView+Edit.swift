#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Edit menu.
public import AppKit
import AVFoundation

/// An Edit menu command of a hosted page (plans/cmux-next/chrome-parity/p01-process.md, task 047):
/// Blink's editor command name, which `cmux_shim_browser_edit_command` runs on the page's focused
/// frame. Chrome's page view sends the same commands to its browser as RenderWidgetHostNSViewHost's
/// Undo, Redo, Cut, Copy, Paste, PasteAndMatchStyle and SelectAll
/// (content/common/render_widget_host_ns_view.mojom).
nonisolated enum ChromiumHostEditCommand: String, CaseIterable, Sendable {
    case undo = "Undo"
    case redo = "Redo"
    case cut = "Cut"
    case copy = "Copy"
    case paste = "Paste"
    case pasteAndMatchStyle = "PasteAndMatchStyle"
    case delete = "Delete"
    case selectAll = "SelectAll"

    /// The command as a kEdit frame (v0 0 copy, 1 cut, 2 paste, 3 select all, 4 undo, 5 redo), the
    /// form a hosted widget takes; nil for a command that frame has no code for.
    var editFrame: ChromiumHostFrame? {
        let code: Int32? = switch self {
        case .copy: 0
        case .cut: 1
        case .paste: 2
        case .selectAll: 3
        case .undo: 4
        case .redo: 5
        case .pasteAndMatchStyle, .delete: nil
        }
        return code.map { ChromiumHostFrame(.edit, v: [$0]) }
    }
}

/// Speaks text for a page view's Start Speaking (``ChromiumHostSpeechSynthesizer`` in the app).
@MainActor protocol ChromiumHostSpeaking: AnyObject {
    var isSpeaking: Bool { get }
    /// Speaks `text`, ending what was being spoken.
    func speak(_ text: String)
    func stopSpeaking()
}

/// ``ChromiumHostSpeaking`` with the system voice.
@MainActor final class ChromiumHostSpeechSynthesizer: ChromiumHostSpeaking {
    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) {
        _ = synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func stopSpeaking() {
        _ = synthesizer.stopSpeaking(at: .immediate)
    }
}

/// The Edit menu, Services, Start Speaking and Look Up of a hosted page (task 047), as Chrome's
/// `RenderWidgetHostViewCocoa` has them (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm).
/// Edit commands go to ``editCommandSink`` (the session's ordered stream, or the host's
/// `cmux_shim_browser_edit_command` post). Everything that reads the page's text reads the
/// selection the host pushed ahead (``ChromiumHostTextInputState``, task 044) and asks the host
/// nothing: Chrome keeps the same selection in its browser for Services and speech
/// (`TextInputManager::TextSelection`) and still asks the browser `SyncIsSpeaking`; cmux speaks in
/// its own process, so whether it is speaking needs no message at all.
extension ChromiumHostPageView {
    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) { editCommandSink?(.copy) }
    @objc public func cut(_ sender: Any?) { editCommandSink?(.cut) }
    @objc public func paste(_ sender: Any?) { editCommandSink?(.paste) }
    @objc public func pasteAndMatchStyle(_ sender: Any?) { editCommandSink?(.pasteAndMatchStyle) }
    /// cmux's Paste and Match Style item (Cmd-Shift-V) sends NSTextView's selector.
    @objc public func pasteAsPlainText(_ sender: Any?) { editCommandSink?(.pasteAndMatchStyle) }
    @objc public func delete(_ sender: Any?) { editCommandSink?(.delete) }
    @objc public override func selectAll(_ sender: Any?) { editCommandSink?(.selectAll) }
    @objc public func undo(_ sender: Any?) { editCommandSink?(.undo) }
    @objc public func redo(_ sender: Any?) { editCommandSink?(.redo) }

    // MARK: Speech

    @objc public func startSpeaking(_ sender: Any?) {
        guard let text = selectedPageText else { return }
        speech.speak(text)
    }

    @objc public func stopSpeaking(_ sender: Any?) {
        speech.stopSpeaking()
    }

    // MARK: Look Up

    /// Look Up (a force click, a three-finger tap): the definition of the page's selection, at its
    /// first line. Chrome asks its renderer for the word under the pointer
    /// (`LookUpDictionaryOverlayAtPoint`); cmux has only the pushed selection and asks nothing.
    public override func quickLook(with event: NSEvent) {
        if !showDefinitionForSelection() { super.quickLook(with: event) }
    }

    /// Shows the dictionary panel for the page's selection; false without one.
    @discardableResult
    func showDefinitionForSelection() -> Bool {
        guard let text = selectedPageText else { return false }
        // Page points have a top-left origin; this view's are bottom-left, and the panel takes a baseline.
        let line = textInput.state.caretRect
        showDefinition(for: NSAttributedString(string: text), at: NSPoint(x: line.minX, y: bounds.height - line.maxY))
        return true
    }

    // MARK: Pushed selection

    /// The page's selected text from the host's last push; nil without a selection, when the push
    /// holds only part of it (longer than the host sends), and in a password field.
    var selectedPageText: String? {
        let state = textInput.state
        guard state.type != .password, let selection = state.selection, !selection.isEmpty,
              let found = state.substring(of: selection, markedText: []), found.actual == selection else { return nil }
        return found.text
    }
}

extension ChromiumHostPageView: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startSpeaking(_:)): selectedPageText != nil
        case #selector(stopSpeaking(_:)): speech.isSpeaking
        default: true
        }
    }
}

/// Services (`-[RenderWidgetHostViewCocoa validRequestorForSendType:returnType:]` and its pasteboard
/// methods): the selection goes out as plain text, and text a service returns goes into the field.
extension ChromiumHostPageView: NSServicesMenuRequestor {
    public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                        returnType: NSPasteboard.PasteboardType?) -> Any? {
        let sendsText = sendType == .string
        let returnsText = returnType == .string
        let hasText = selectedPageText != nil
        let takesText = textInput.state.type.takesInputMethod
        if (sendsText && hasText && returnType == nil) || (sendType == nil && returnsText && takesText)
            || (sendsText && returnsText && hasText && takesText) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    public func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), let text = selectedPageText else { return false }
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }

    /// The service's text replaces the selection; an open composition ends first with its text
    /// kept, as Chrome confirms it before it inserts.
    public func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let text = pboard.string(forType: .string) else { return false }
        textInputMouseDown()
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
}
#endif
