#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Edit menu.
public import AppKit
import AVFoundation

/// An Edit menu command of a hosted page (plans/cmux-next/chrome-parity/p01-process.md, task 047):
/// Blink's editor command name, which `cmux_shim_browser_edit_command` runs on the page's focused
/// frame. Chrome's page view sends the same commands to its browser as RenderWidgetHostNSViewHost's
/// Undo, Redo, Cut, Copy, Paste, PasteAndMatchStyle and SelectAll
/// (content/common/render_widget_host_ns_view.mojom), and Jump to Selection as its CenterSelection.
nonisolated enum ChromiumHostEditCommand: String, CaseIterable, Sendable {
    case undo = "Undo"
    case redo = "Redo"
    case cut = "Cut"
    case copy = "Copy"
    case paste = "Paste"
    case pasteAndMatchStyle = "PasteAndMatchStyle"
    case delete = "Delete"
    case selectAll = "SelectAll"
    /// Jump to Selection (`centerSelectionInVisibleArea:`): Chrome's `FrameInputHandler::CenterSelection`,
    /// which the shim runs through the fork's `cmux_browser_center_selection` (task p01-process-242).
    case centerSelection = "CenterSelection"

    /// The first fork API with `cmux_browser_center_selection`: max + 1 of the numbers the app claims
    /// (38 is ``CEFForkFeatures/surfaceCopyForkAPI``), which the fork task p01-process-242 sets with its pin.
    static let centerSelectionForkAPI: Int32 = 39

    /// Whether a page on fork API `forkAPI` runs the command: all of them, and center selection from
    /// ``centerSelectionForkAPI`` (below it the shim has no fork call to run it with).
    func runs(onForkAPI forkAPI: Int32) -> Bool {
        self != .centerSelection || forkAPI >= Self.centerSelectionForkAPI
    }

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
        case .pasteAndMatchStyle, .delete, .centerSelection: nil
        }
        return code.map { ChromiumHostFrame(.edit, v: [$0]) }
    }
}

extension ChromiumHostEditCommand {
    /// Where a page view's Edit menu commands go, and which of them that route runs. The menu item
    /// of a command the route does not run shows disabled, and its action sends nothing.
    @MainActor struct Route {
        /// Whether the route runs `command` now.
        let runs: (ChromiumHostEditCommand) -> Bool
        /// Sends a command ``runs`` took.
        let send: (ChromiumHostEditCommand) -> Void
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

/// The Edit menu, Services, Start Speaking and selection Look Up of a hosted page (task 047), as Chrome's
/// `RenderWidgetHostViewCocoa` has them (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm).
/// Edit commands go to ``editCommandRoute`` (the session's ordered stream, the host's
/// `cmux_shim_browser_edit_command` post, or a hosted widget's kEdit frames). Everything that
/// reads the page's text reads the selection the host pushed ahead (``ChromiumHostTextInputState``,
/// task 044) and asks the host nothing: Chrome keeps the same selection in its browser for Services and speech
/// (`TextInputManager::TextSelection`) and still asks the browser `SyncIsSpeaking`; cmux speaks in
/// its own process, so whether it is speaking needs no message at all.
extension ChromiumHostPageView {
    // MARK: Edit menu

    @objc public func copy(_ sender: Any?) { runEditCommand(.copy) }
    @objc public func cut(_ sender: Any?) { runEditCommand(.cut) }
    @objc public func paste(_ sender: Any?) { runEditCommand(.paste) }
    @objc public func pasteAndMatchStyle(_ sender: Any?) { runEditCommand(.pasteAndMatchStyle) }
    /// cmux's Paste and Match Style item (Cmd-Shift-V) sends NSTextView's selector.
    @objc public func pasteAsPlainText(_ sender: Any?) { runEditCommand(.pasteAndMatchStyle) }
    @objc public func delete(_ sender: Any?) { runEditCommand(.delete) }
    @objc public override func selectAll(_ sender: Any?) { runEditCommand(.selectAll) }
    @objc public func undo(_ sender: Any?) { runEditCommand(.undo) }
    @objc public func redo(_ sender: Any?) { runEditCommand(.redo) }
    /// Edit > Find > Jump to Selection (Cmd-J), as
    /// `-[RenderWidgetHostViewCocoa centerSelectionInVisibleArea:]`.
    @objc public override func centerSelectionInVisibleArea(_ sender: Any?) { runEditCommand(.centerSelection) }

    /// The Edit menu command an action selector names; nil for any other selector.
    static func editCommand(for action: Selector?) -> ChromiumHostEditCommand? {
        switch action {
        case #selector(ChromiumHostPageView.copy(_:)): .copy
        case #selector(ChromiumHostPageView.cut(_:)): .cut
        case #selector(ChromiumHostPageView.paste(_:)): .paste
        case #selector(ChromiumHostPageView.pasteAndMatchStyle(_:)),
             #selector(ChromiumHostPageView.pasteAsPlainText(_:)): .pasteAndMatchStyle
        case #selector(ChromiumHostPageView.delete(_:)): .delete
        case #selector(ChromiumHostPageView.selectAll(_:)): .selectAll
        case #selector(ChromiumHostPageView.undo(_:)): .undo
        case #selector(ChromiumHostPageView.redo(_:)): .redo
        case #selector(ChromiumHostPageView.centerSelectionInVisibleArea(_:)): .centerSelection
        default: nil
        }
    }

    /// Whether the page's route runs `command` now; false with no route.
    func runsEditCommand(_ command: ChromiumHostEditCommand) -> Bool {
        editCommandRoute?.runs(command) ?? false
    }

    private func runEditCommand(_ command: ChromiumHostEditCommand) {
        guard let route = editCommandRoute, route.runs(command) else { return }
        route.send(command)
    }

    // MARK: Speech

    @objc public func startSpeaking(_ sender: Any?) {
        guard let text = selectedPageText else { return }
        speech.speak(text)
    }

    @objc public func stopSpeaking(_ sender: Any?) {
        speech.stopSpeaking()
    }

    // MARK: Look Up

    /// Look Up of the page's selection, at its first line: what a force click or three-finger tap
    /// shows when the pane has no word lookup (``quickLook(with:)`` in ChromiumHostPageView+LookUp.swift
    /// asks the renderer for the word under the pointer, as Chrome does). Shows the dictionary panel
    /// for the pushed selection; false without one.
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
        if let command = Self.editCommand(for: menuItem.action) { return runsEditCommand(command) }
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
