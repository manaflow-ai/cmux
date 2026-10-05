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

    init(view: TerminalSurfaceView) {
        self.view = view
    }

    /// Serves a clipboard read with the pasteboard's text (and, when asked,
    /// the list of available types). Unavailable when there is nothing to
    /// serve, so a paste binding can fall through to the terminal.
    func completeRead(location: TerminalPasteboardLocation, wantsText: Bool, listAvailable: Bool,
                      state: UncheckedPointer) -> ghostty_clipboard_read_result_e {
        guard let surface = view?.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let text = TerminalPasteboard.pasteText(from: TerminalPasteboard.pasteboard(location))
        let served = wantsText ? text : nil
        if served == nil, !listAvailable { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        Self.complete(surface, text: served, available: listAvailable && text != nil ? ["text/plain"] : [],
                      state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Unsafe paste (newlines while bracketed paste is off) or an OSC 52 read
    /// when `clipboard-read = ask`: a cmux dialog that blocks only this
    /// terminal. Denial completes with an empty string, as Ghostty expects.
    func confirm(contents: String, kind: TerminalClipboardRequestKind, state: UncheckedPointer) {
        guard let view, view.window != nil else {
            deny(state: state)
            return
        }
        let spec = switch kind {
        case .paste:
            Self.spec(String(localized: "terminal.clipboard.paste.title", defaultValue: "Paste into the terminal?", bundle: .module),
                      String(localized: "terminal.clipboard.paste.message", defaultValue: "The text contains line breaks and may run commands immediately.", bundle: .module),
                      preview: contents)
        case .osc52Read, .osc52Write:
            Self.spec(String(localized: "terminal.clipboard.read.title", defaultValue: "Allow a program to read the clipboard?", bundle: .module),
                      String(localized: "terminal.clipboard.read.message", defaultValue: "A program running in this terminal asked for the clipboard contents.", bundle: .module),
                      preview: contents)
        }
        CmuxDialogCenter.shared.present(spec, in: .tab(view)) { [weak self] answer in
            guard let self else { return }
            if answer.button == "allow" { complete(state: state, with: contents) } else { deny(state: state) }
        }
    }

    /// OSC 52 write when `clipboard-write = ask`.
    func confirmWrite(items: [TerminalClipboardItem], location: TerminalPasteboardLocation) {
        guard let view, view.window != nil else { return }
        let text = items.first(where: { $0.mime.hasPrefix("text/plain") })?.text ?? items.first?.text ?? ""
        let spec = Self.spec(String(localized: "terminal.clipboard.write.title", defaultValue: "Allow a program to change the clipboard?", bundle: .module),
                             String(localized: "terminal.clipboard.write.message", defaultValue: "A program running in this terminal wants to copy text to the clipboard.", bundle: .module),
                             preview: text)
        CmuxDialogCenter.shared.present(spec, in: .tab(view)) { answer in
            guard answer.button == "allow" else { return }
            TerminalPasteboard.write(items, to: location)
        }
    }

    /// Allow (Return) or Deny (Escape), with a preview of the text.
    static func spec(_ title: String, _ message: String, preview text: String) -> CmuxDialogSpec {
        let limit = 2_000
        let preview = text.count > limit ? String(text.prefix(limit)) + "…" : text
        return CmuxDialogSpec(
            title: title, lines: [message], fields: [.preview(preview)],
            buttons: [
                CmuxDialogButton(id: "deny", title: String(localized: "terminal.clipboard.deny", defaultValue: "Deny", bundle: .module), role: .cancel),
                CmuxDialogButton(id: "allow", title: String(localized: "terminal.clipboard.allow", defaultValue: "Allow", bundle: .module), role: .default),
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
