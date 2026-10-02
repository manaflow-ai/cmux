import AppKit
import GhosttyKit

/// Ghostty's clipboard requests for one terminal view: clipboard reads,
/// and the confirmations for an unsafe paste or an OSC 52 read or write
/// (a sheet on the view's window). Denial completes a read with an empty
/// string, as Ghostty expects.
@MainActor
final class TerminalClipboardRequests {
    weak var view: TerminalSurfaceView?

    init(view: TerminalSurfaceView) {
        self.view = view
    }

    func completeRead(location: TerminalPasteboardLocation, state: UncheckedPointer) -> Bool {
        guard let surface = view?.surface, let text = TerminalPasteboard.pasteText(from: TerminalPasteboard.pasteboard(location)) else {
            return false
        }
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state.raw, false)
        }
        return true
    }

    /// Unsafe paste (newlines while bracketed paste is off) or an OSC 52 read
    /// when `clipboard-read = ask`. Denial completes with an empty string, as
    /// Ghostty expects.
    func confirm(contents: String, kind: TerminalClipboardRequestKind, state: UncheckedPointer) {
        guard let window = view?.window else {
            complete(state: state, with: "")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case .paste:
            alert.messageText = String(localized: "terminal.clipboard.paste.title", defaultValue: "Paste into the terminal?", bundle: .module)
            alert.informativeText = String(localized: "terminal.clipboard.paste.message", defaultValue: "The text contains line breaks and may run commands immediately.", bundle: .module)
        case .osc52Read, .osc52Write:
            alert.messageText = String(localized: "terminal.clipboard.read.title", defaultValue: "Allow a program to read the clipboard?", bundle: .module)
            alert.informativeText = String(localized: "terminal.clipboard.read.message", defaultValue: "A program running in this terminal asked for the clipboard contents.", bundle: .module)
        }
        alert.accessoryView = Self.previewField(contents)
        alert.addButton(withTitle: String(localized: "terminal.clipboard.allow", defaultValue: "Allow", bundle: .module))
        alert.addButton(withTitle: String(localized: "terminal.clipboard.deny", defaultValue: "Deny", bundle: .module))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.complete(state: state, with: response == .alertFirstButtonReturn ? contents : "")
            }
        }
    }

    /// OSC 52 write when `clipboard-write = ask`.
    func confirmWrite(items: [TerminalClipboardItem], location: TerminalPasteboardLocation) {
        guard let window = view?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "terminal.clipboard.write.title", defaultValue: "Allow a program to change the clipboard?", bundle: .module)
        alert.informativeText = String(localized: "terminal.clipboard.write.message", defaultValue: "A program running in this terminal wants to copy text to the clipboard.", bundle: .module)
        alert.accessoryView = Self.previewField(items.first(where: { $0.mime.hasPrefix("text/plain") })?.text ?? items[0].text)
        alert.addButton(withTitle: String(localized: "terminal.clipboard.allow", defaultValue: "Allow", bundle: .module))
        alert.addButton(withTitle: String(localized: "terminal.clipboard.deny", defaultValue: "Deny", bundle: .module))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { TerminalPasteboard.write(items, to: location) }
        }
    }

    private func complete(state: UncheckedPointer, with text: String) {
        guard let surface = view?.surface else { return }
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state.raw, true)
        }
    }

    private static func previewField(_ text: String) -> NSView {
        let limit = 2_000
        let preview = text.count > limit ? String(text.prefix(limit)) + "…" : text
        let field = NSTextField(wrappingLabelWithString: preview)
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 8
        field.preferredMaxLayoutWidth = 320
        field.frame = NSRect(x: 0, y: 0, width: 320, height: min(field.intrinsicContentSize.height, 140))
        return field
    }
}
