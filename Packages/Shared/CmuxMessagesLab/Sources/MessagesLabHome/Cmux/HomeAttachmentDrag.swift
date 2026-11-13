import AppKit
import UniformTypeIdentifiers

/// cmux: a Home attachment dragged out of the transcript, to Finder, the Desktop or another app
/// (the user, 2026-10-21). When the press already fetched the file the drag carries it
/// (``HomeAttachmentPasteboard``: the file URL, and an image's bytes); before then it is a file
/// promise that fetches the bytes when the drop asks, so a drag never waits on the network.
/// It is also the drag's source: a copy everywhere (Home's bytes stay where they are).
final class HomeAttachmentDrag: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    /// The attachment's name, the dropped file's name.
    let name: String
    private let resolve: @MainActor @Sendable () async -> URL?

    init(name: String, resolve: @escaping @MainActor @Sendable () async -> URL?) {
        self.name = name
        self.resolve = resolve
    }

    /// The name as one plain file name ("file" when nothing is left).
    var fileName: String {
        let leaf = (name as NSString).lastPathComponent
        return leaf.isEmpty || leaf == "." || leaf == ".." ? "file" : leaf
    }

    /// The drag's pasteboard writer: the file when `file` is fetched, else a promise of it.
    func writer(file: URL?) -> NSPasteboardWriting {
        if let file { return HomeAttachmentPasteboard().item(for: file) }
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
        return NSFilePromiseProvider(fileType: type.identifier, delegate: self)
    }

    /// The drag image: the picture itself for an image (at most 240 pt on its long side), else
    /// the file type's icon.
    func preview(file: URL?, size: CGSize) -> NSImage {
        if let file, let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
           let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0 {
            let side = min(240, max(size.width, size.height, 64))
            let scale = side / max(image.size.width, image.size.height)
            image.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return image
        }
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = CGSize(width: 64, height: 64)
        return icon
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let resolve = self.resolve
        // task-owner: one fetch for the drop; ends when the file is written or refused
        Task { @MainActor in
            guard let file = await resolve() else {
                completionHandler(CocoaError(.fileReadNoSuchFile))
                return
            }
            do {
                try HomeAttachmentSave().save(file, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
