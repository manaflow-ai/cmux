import AppKit

/// Identifies one immutable generation of a named pasteboard without carrying AppKit objects across executors.
struct TerminalPasteboardReadRequest: Codable, Sendable {
    let pasteboardName: String
    let changeCount: Int

    init(pasteboardName: String, changeCount: Int) {
        self.pasteboardName = pasteboardName
        self.changeCount = changeCount
    }

    @MainActor
    init(pasteboard: NSPasteboard) {
        self.init(
            pasteboardName: pasteboard.name.rawValue,
            changeCount: pasteboard.changeCount
        )
    }
}
