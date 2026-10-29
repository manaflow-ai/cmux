import AppKit
import CmuxNextCompat

/// A file's own rows ahead of its path menu in an agent chat (a file chip, a video, an audio
/// clip): Copy (the file, as Finder's Copy, and an image's bytes) and Save As… (the save panel
/// under its name). The user, 2026-10-21: Copy, Save As and Show in Finder for videos and files,
/// not only images; Reveal in Finder is the path menu's own row.
@MainActor
struct AgentPaneFileRows {
    /// Copy: writes the item to the general pasteboard (``AgentPaneImageCopies/writeGeneral(_:)``);
    /// tests record it instead.
    var copyItem: @MainActor (NSPasteboardItem) -> Bool = { AgentPaneImageCopies.writeGeneral($0) }
    /// Save As…: asks where to save the file under the name.
    var save: @MainActor (_ file: URL, _ name: String) -> Void = { AgentPaneImageCopies.askToSave($0, name: $1) }
    /// Whether the rows may still touch the file; Copy checks it before its read and again
    /// before the pasteboard (a path menu's: the chat is still on this Mac).
    var allowed: @MainActor () -> Bool = { true }
    /// The app's blocking-work lanes: Copy reads an image's bytes there.
    let runner: any MayBlockRunner

    /// Copy and Save As… for `file`.
    func items(for file: URL) -> [NSMenuItem] {
        let rows = self
        return [
            AgentPaneMenuAction.item(AgentPaneMenuStrings.copyFile, symbol: "doc.on.doc") {
                // task-owner: one read of an image's bytes off the main actor; ends when the pasteboard is written
                // main-hop-allow: the person's Copy, userBlocking (p06 rule 2): pasteboardImage reads the bytes off
                // main; this task only starts it, and its one resume writes the pasteboard (main-only)
                Task { @MainActor in _ = await rows.copy(file) }
            },
            AgentPaneMenuAction.item(AgentPaneMenuStrings.saveAs, symbol: "square.and.arrow.down") {
                rows.save(file, file.lastPathComponent)
            },
        ]
    }

    /// Copy: `file` (and an image's bytes) on the pasteboard.
    func copy(_ file: URL) async -> Bool {
        guard allowed() else { return false }
        let image = await AgentPaneImageCopies.pasteboardImage(file, runner: runner)
        guard allowed() else { return false }
        return copyItem(AgentPaneImageCopies.pasteboardItem(file, image: image))
    }
}
