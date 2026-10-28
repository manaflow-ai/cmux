import AppKit
import CmuxNextCompat
import UniformTypeIdentifiers

/// The context menu's Copy Image, Save Image As… and Quick Look on an image in an agent chat (the
/// user, 2026-10-21: "right click any image/video etc 'copy'"). Each acts on the image's named copy
/// (``AgentPaneImageCopies/copy(_:name:in:)``), so the pasteboard, the saved file and the preview
/// all get a real file with its type's extension.
extension AgentPaneImageCopies {
    /// Spends the person's gesture, makes `src`'s copy and runs `action` on it.
    @MainActor static func withCopy(_ src: String, name: String, in model: AgentPaneModel,
                                    _ action: @MainActor (URL) async -> Void) async -> [String: Any] {
        guard model.transport.gestures.consume() else { return AgentPaneModel.replyFailure(.gestureRequired) }
        switch await copy(src, name: name, in: model.replyLinks.imageFolder) {
        case .success(let file):
            await action(file)
            return AgentPaneReply.success()
        case .failure(let error):
            return AgentPaneModel.replyFailure(error)
        }
    }

    /// Copy: replaces the general pasteboard's contents with `item`, as Finder's Copy does (the
    /// file URL, so Finder, Messages, Mail and Slack paste the file; an image's bytes too, so
    /// Preview and apps that read only image data paste the picture).
    @discardableResult
    static func writeGeneral(_ item: NSPasteboardItem) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }

    /// The pasteboard item for `file` (Copy): its file URL, its name, and an image's bytes under its type and its
    /// TIFF (``AgentPanePasteboardImage``, made off the main actor), so the main thread decodes nothing here.
    @MainActor static func pasteboardItem(_ file: URL, image: AgentPanePasteboardImage?) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.lastPathComponent, forType: .string)
        if let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image), let image {
            item.setData(image.data, forType: NSPasteboard.PasteboardType(type.identifier))
            if let tiff = image.tiff { item.setData(tiff, forType: .tiff) }
        }
        return item
    }

    /// An image file's bytes and their TIFF, read and made off the main actor; nil for another type or a failed read.
    @concurrent static func pasteboardImage(_ file: URL) async -> AgentPanePasteboardImage? {
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return AgentPanePasteboardImage(data, type: type)
    }

    /// The name Save Image As… offers: the image's name with its copy's extension (no hash), or the
    /// copy's own name when the image has none.
    static func savedName(_ name: String, file: URL) -> String {
        let leaf = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (leaf as NSString).deletingPathExtension
        guard !base.isEmpty, !base.hasPrefix("."), !leaf.contains(":") else { return file.lastPathComponent }
        return "\(base).\(file.pathExtension)"
    }

    /// Save Image As…: the system save panel under `name`, then a copy of `file` where the person
    /// chose (an older file there is replaced: the panel asked); a failed write beeps (the panel
    /// only offers folders the person can write, so this is a full disk or a vanished volume).
    @MainActor static func askToSave(_ file: URL, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.checked.fileExists(atPath: destination.path) {
                    _ = try FileManager.checked.replaceItemAt(destination, withItemAt: try stagedCopy(of: file, beside: destination))
                } else {
                    try FileManager.checked.copyItem(at: file, to: destination)
                }
            } catch {
                NSSound.beep()
            }
        }
    }

    /// A copy of `file` in `destination`'s folder, for an atomic replace.
    private static func stagedCopy(of file: URL, beside destination: URL) throws -> URL {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        try FileManager.default.copyItem(at: file, to: staged)
        return staged
    }
}
