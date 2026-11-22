public import AppKit
import GhosttyNextKit

/// One read of a terminal's selection (`ghostty_surface_read_selection`):
/// its text, its range in the screen text and its top-left corner in
/// points. The surface view's text input, accessibility and Services paths
/// share this read instead of each freeing the Ghostty text itself.
struct TerminalSelection {
    let text: String
    let range: NSRange
    let topLeft: CGPoint

    /// The surface's selection, or nil when nothing is selected.
    static func read(_ surface: ghostty_surface_t?) -> Self? {
        guard let surface else { return nil }
        var raw = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &raw) else { return nil }
        defer { ghostty_surface_free_text(surface, &raw) }
        let text = raw.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(raw.text_len)), as: UTF8.self) } ?? ""
        return Self(text: text, range: NSRange(location: Int(raw.offset_start), length: Int(raw.offset_len)),
                    topLeft: CGPoint(x: raw.tl_px_x, y: raw.tl_px_y))
    }
}

/// Services for a terminal selection (cx-k9go): plain text out, nothing
/// written back. A right-click on selected text lists the text services
/// (AppKit adds them to the context menu) and the app's Services menu
/// offers them too.
enum TerminalServices {
    static let types: Set<NSPasteboard.PasteboardType> = [.string, NSPasteboard.PasteboardType("public.utf8-plain-text")]

    static func accepts(_ sendType: NSPasteboard.PasteboardType?, _ returnType: NSPasteboard.PasteboardType?, hasSelection: Bool) -> Bool {
        returnType == nil && sendType.map(types.contains) == true && hasSelection
    }

    static func write(_ text: String?, to pboard: NSPasteboard, types requested: [NSPasteboard.PasteboardType]) -> Bool {
        write(text, types: requested) { pboard.clearContents(); return pboard.setString($0, forType: .string) }
    }

    /// The selection a service gets, through `set` (the pasteboard write).
    static func write(_ text: String?, types requested: [NSPasteboard.PasteboardType], set: (String) -> Bool) -> Bool {
        guard requested.contains(where: types.contains), let text, !text.isEmpty else { return false }
        return set(text)
    }
}
