import AppKit
import CmuxNextDesign
import GhosttyNextKit

/// Ghostty's clipboard requests for one terminal view: clipboard reads,
/// and the confirmations for an unsafe paste or an OSC 52 read or write
/// (a cmux dialog that blocks only this terminal). Denial completes a read with an empty
/// string, as Ghostty expects.
@MainActor
final class TerminalClipboardRequests {
    weak var view: TerminalSurfaceView?
    /// Set while a user paste (Cmd-V, Edit > Paste) runs. Ghostty asks for
    /// the clipboard synchronously inside it; only then may a clipboard image
    /// be saved and its path served. A program's OSC 52 read never is.
    var userPasteInProgress = false
    /// True only during a synchronous Ghostty key/binding call initiated by
    /// the user. A copy callback inside that call is not program output.
    private var userClipboardWriteInProgress = false
    /// At most one program-write dialog per surface; later writes are denied
    /// instead of growing the global dialog queue.
    private var writePromptPending = false
    private var writeDialogID: Int?
    private var writeRequestState: UncheckedPointer?
    nonisolated static let maxProgramWriteBytes = 1 << 20

    /// Runs `body` as a user paste (see `userPasteInProgress`).
    func asUserPaste<T>(_ body: () -> T) -> T {
        let previous = userPasteInProgress
        userPasteInProgress = true
        defer { userPasteInProgress = previous }
        return body()
    }

    /// Marks the synchronous Ghostty call made by a user's copy key or menu.
    func asUserClipboardWrite<T>(_ body: () -> T) -> T {
        let previous = userClipboardWriteInProgress
        userClipboardWriteInProgress = true
        defer { userClipboardWriteInProgress = previous }
        return body()
    }

    /// Whether `event` is the Cmd-V paste chord.
    static func isPasteChord(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    init(view: TerminalSurfaceView) {
        self.view = view
    }

    /// Serves a clipboard read with the pasteboard's text (and, when asked,
    /// the list of available types). A system clipboard holding only an
    /// image serves, during a user paste only, the path of that image saved to a temporary file, as in
    /// the shipping cmux. Unavailable when there is nothing to serve, so a
    /// paste binding can fall through to the terminal.
    func completeRead(location: TerminalPasteboardLocation, wantsText: Bool, listAvailable: Bool,
                      state: UncheckedPointer) -> ghostty_clipboard_read_result_e {
        guard let surface = view?.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let pasteboard = TerminalPasteboard.pasteboard(location)
        let imagePaste = location == .standard && userPasteInProgress
        let text: String? = if imagePaste, wantsText {
            TerminalPasteboard.pasteTextSavingImage(from: pasteboard)
        } else if imagePaste, TerminalPasteboard.pasteText(from: pasteboard) == nil,
                  TerminalPasteboard.hasImage(pasteboard) {
            ""
        } else {
            TerminalPasteboard.pasteText(from: pasteboard)
        }
        let served = wantsText ? text : nil
        if served == nil, !listAvailable { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        Self.complete(surface, text: served, available: listAvailable && text != nil ? ["text/plain"] : [],
                      state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Unsafe paste (newlines while bracketed paste is off) or an OSC 52 read
    /// when `clipboard-read = ask`: a cmux dialog that blocks only this
    /// terminal. Denial completes with an empty string, as Ghostty expects.
    func confirm(contents: String, contentBytes: Int, kind: TerminalClipboardRequestKind, state: UncheckedPointer) {
        if case .osc52Write = kind {
            confirmProgramWrite(contents: contents, contentBytes: contentBytes, state: state)
            return
        }
        guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else {
            deny(state: state)
            return
        }
        let spec: CmuxDialogSpec
        switch kind {
        case .paste:
            spec = Self.spec(String(localized: "terminal.clipboard.paste.title", defaultValue: "Paste into the terminal?", bundle: .module),
                             String(localized: "terminal.clipboard.paste.message", defaultValue: "The text contains line breaks and may run commands immediately.", bundle: .module),
                             preview: contents)
        case .osc52Read:
            spec = Self.spec(String(localized: "terminal.clipboard.read.title", defaultValue: "Allow a program to read the clipboard?", bundle: .module),
                             String(localized: "terminal.clipboard.read.message", defaultValue: "A program running in this terminal asked for the clipboard contents.", bundle: .module),
                             preview: contents)
        case .osc52Write: return  // handled before the visibility guard
        }
        CmuxDialogCenter.shared.present(spec, in: .tab(view)) { [weak self] answer in
            guard let self else { return }
            if answer.button == "allow" { complete(state: state, with: contents) } else { deny(state: state) }
        }
    }

    /// OSC 52 write when `clipboard-write = ask`.
    func confirmWrite(items: [TerminalClipboardItem], location: TerminalPasteboardLocation) {
        guard bounded(items), beginWritePrompt(state: nil), let scope = writePromptScope() else { return }
        let text = items.first(where: { $0.mime.hasPrefix("text/plain") })?.text ?? items.first?.text ?? ""
        writeDialogID = CmuxDialogCenter.shared.present(Self.writeSpec(preview: text), in: scope) { [self] answer in
            finishWritePrompt()
            guard answer.button == "allow" else { return }
            TerminalPasteboard.write(items, to: location)
        }
    }

    /// Ghostty's write callback. Ghostty already applied `clipboard-write`:
    /// it asks for confirmation only when the user set `ask` (and drops the
    /// write for `deny`), so an unconfirmed write is committed silently.
    func write(items: [TerminalClipboardItem], location: TerminalPasteboardLocation, requiresConfirmation: Bool) {
        switch Self.writeDecision(userInitiated: userClipboardWriteInProgress,
                                  requiresConfirmation: requiresConfirmation) {
        case .write:
            guard userClipboardWriteInProgress || bounded(items) else { return }
            TerminalPasteboard.write(items, to: location)
        case .confirm:
            confirmWrite(items: items, location: location)
        }
    }

    /// What a clipboard write callback does: a user's own copy always
    /// writes; a program write asks only when Ghostty's config says `ask`.
    nonisolated static func writeDecision(userInitiated: Bool, requiresConfirmation: Bool) -> TerminalClipboardWriteDecision {
        userInitiated || !requiresConfirmation ? .write : .confirm
    }

    private func confirmProgramWrite(contents: String, contentBytes: Int, state: UncheckedPointer) {
        guard contentBytes <= Self.maxProgramWriteBytes,
              beginWritePrompt(state: state), let scope = writePromptScope() else {
            deny(state: state)
            return
        }
        writeDialogID = CmuxDialogCenter.shared.present(Self.writeSpec(preview: contents), in: scope) { [self] answer in
            finishWritePrompt()
            guard answer.button == "allow" else {
                deny(state: state)
                return
            }
            complete(state: state, with: contents)
        }
    }

    private func beginWritePrompt(state: UncheckedPointer?) -> Bool {
        guard !writePromptPending else { return false }
        writePromptPending = true
        writeRequestState = state
        return true
    }

    /// Ends a write request before this surface closes or is replaced. A
    /// window/app-scoped dialog must not outlive the Ghostty state it answers.
    func cancelPendingWrite() {
        guard writePromptPending else { return }
        if let id = writeDialogID, CmuxDialogCenter.shared.dismiss(id) { return }
        let state = writeRequestState
        finishWritePrompt()
        if let state { deny(state: state) }
    }

    private func finishWritePrompt() {
        writePromptPending = false
        writeDialogID = nil
        writeRequestState = nil
    }

    private func writePromptScope() -> CmuxDialogScope? {
        guard let view else {
            finishWritePrompt()
            return nil
        }
        if view.window != nil, !view.isHiddenOrHasHiddenAncestor { return .tab(view) }
        if let window = view.window { return .window(window) }
        return .app
    }

    private func bounded(_ items: [TerminalClipboardItem]) -> Bool {
        var total = 0
        for item in items {
            let count = item.mime.utf8.count + item.text.utf8.count
            guard count <= Self.maxProgramWriteBytes - total else { return false }
            total += count
        }
        return true
    }

    private static func writeSpec(preview: String) -> CmuxDialogSpec {
        spec(String(localized: "terminal.clipboard.write.title", defaultValue: "Allow a program to change the clipboard?", bundle: .module),
             String(localized: "terminal.clipboard.write.message", defaultValue: "A program running in this terminal wants to copy text to the clipboard.", bundle: .module),
             preview: preview)
    }
    /// Deny on Escape, with a preview of the text. Allow has no key: a
    /// Return typed into the terminal as the dialog opens must never paste
    /// or hand over the clipboard (as in the clipboard-read broker dialog).
    static func spec(_ title: String, _ message: String, preview text: String) -> CmuxDialogSpec {
        let limit = 2_000
        let preview = text.count > limit ? String(text.prefix(limit)) + "…" : text
        return CmuxDialogSpec(
            title: title, lines: [message], fields: [.preview(preview)],
            buttons: [
                CmuxDialogButton(id: "deny", title: String(localized: "terminal.clipboard.deny", defaultValue: "Deny", bundle: .module), role: .cancel),
                CmuxDialogButton(id: "allow", title: String(localized: "terminal.clipboard.allow", defaultValue: "Allow", bundle: .module), role: .normal),
            ],
            identifier: "cmux.dialog.terminalClipboard")
    }

    private func complete(state: UncheckedPointer, with text: String) {
        guard let surface = view?.surface else { return }
        Self.complete(surface, text: text, available: [], state: state, confirmed: true)
    }

    /// Denial: Ghostty writes the protocol's denial reply where one exists.
    private func deny(state: UncheckedPointer) {
        guard let surface = view?.surface, let raw = state.raw else { return }
        ghostty_surface_deny_clipboard_request(surface, raw)
    }

    /// `ghostty_surface_complete_clipboard_request` with at most one
    /// text/plain representation. Every pointer is borrowed for the call.
    private static func complete(_ surface: ghostty_surface_t, text: String?, available: [String],
                                 state: UncheckedPointer, confirmed: Bool) {
        let mime = strdup("text/plain")
        let data = text.map { Array($0.utf8) } ?? []
        let availablePointers: [UnsafePointer<CChar>?] = available.map { UnsafePointer(strdup($0)) }
        defer {
            free(mime)
            availablePointers.forEach { free(UnsafeMutableRawPointer(mutating: $0)) }
        }
        data.withUnsafeBufferPointer { bytes in
            bytes.withMemoryRebound(to: CChar.self) { chars in
                var item = ghostty_clipboard_content_s(mime: mime, data: chars.baseAddress, len: chars.count)
                availablePointers.withUnsafeBufferPointer { list in
                    withUnsafePointer(to: &item) { itemPointer in
                        var request = ghostty_clipboard_complete_s(
                            contents: text == nil ? nil : itemPointer,
                            contents_len: text == nil ? 0 : 1,
                            available: list.baseAddress,
                            available_len: list.count,
                            confirmed: confirmed,
                            remember: false)
                        ghostty_surface_complete_clipboard_request(surface, &request, state.raw)
                    }
                }
            }
        }
    }

    /// The text of one clipboard representation (binary-safe, with a length,
    /// not NUL-terminated).
    nonisolated static func string(_ item: ghostty_clipboard_content_s) -> String {
        guard let data = item.data, item.len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
    }
}
