import AppKit

/// cmux: a Home attachment's own menu rows, ahead of the host's file menu (Open in Right Pane,
/// Open With, Quick Look, Show in Finder, Copy Path, Share): Copy (``HomeAttachmentPasteboard``)
/// and Save As… (``HomeAttachmentSave``). The rows are built from the name alone, so the menu
/// opens at once; `resolve` fetches the local copy when a row runs.
struct HomeAttachmentRows {
    /// Where Copy writes (the general pasteboard; a named one in tests).
    var pasteboard: NSPasteboard = .general
    /// The window Save As… is a sheet on.
    weak var window: NSWindow?

    init(pasteboard: NSPasteboard = .general, window: NSWindow? = nil) {
        self.pasteboard = pasteboard
        self.window = window
    }

    /// Copy and Save As… for an attachment named `name`.
    @MainActor func items(name: String, resolve: @escaping @MainActor @Sendable () async -> URL?) -> [NSMenuItem] {
        let rows = self
        return [
            MenuAction(title: CmuxStrings.copyAttachment, symbol: "doc.on.doc") {
                // task-owner: one fetch (the original may download); ends when the pasteboard is written
                Task { @MainActor in _ = await rows.copy(resolve: resolve) }
            },
            MenuAction(title: CmuxStrings.saveAttachmentAs, symbol: "square.and.arrow.down") {
                // task-owner: one fetch; ends when the save panel opens
                Task { @MainActor in
                    guard let file = await resolve() else { return }
                    HomeAttachmentSave().ask(file, name: name, window: rows.window)
                }
            },
        ]
    }

    /// Copy: the attachment's file (and an image's pixels) on the pasteboard; false when its bytes
    /// cannot be read here.
    @MainActor func copy(resolve: @MainActor @Sendable () async -> URL?) async -> Bool {
        guard let file = await resolve() else { return false }
        // The image's bytes are read off the main actor (a large picture would hold a frame).
        let data = await Task.detached(priority: .userInitiated) { HomeAttachmentPasteboard.imageBytes(file) }.value
        return HomeAttachmentPasteboard().write(file, data: .some(data), to: pasteboard)
    }
}
