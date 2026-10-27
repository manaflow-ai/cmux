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

    /// The selection of `view`'s surface, or nil when nothing is selected (or it has no surface).
    @MainActor static func read(of view: TerminalSurfaceView) -> Self? {
        guard let surface = view.surface else { return nil }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        guard let read = unsafe GhosttyTextRead(selectionOf: surface) else { return nil }
        return Self(text: read.string, range: read.range, topLeft: read.topLeft)
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
