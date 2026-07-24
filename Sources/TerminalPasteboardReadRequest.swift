import AppKit

/// Identifies one immutable generation of a named pasteboard without carrying AppKit objects across executors.
struct TerminalPasteboardReadRequest: Sendable {
    let pasteboardName: String
    let changeCount: Int

    @MainActor
    init(pasteboard: NSPasteboard) {
        self.pasteboardName = pasteboard.name.rawValue
        self.changeCount = pasteboard.changeCount
    }
}
