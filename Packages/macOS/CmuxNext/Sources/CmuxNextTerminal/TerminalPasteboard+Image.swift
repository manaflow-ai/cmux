import AppKit
import UniformTypeIdentifiers

/// A clipboard image pasted into a terminal, as in the shipping cmux: when the
/// clipboard holds an image and no text, the image is written to a temporary
/// file and its shell-escaped path is pasted, so an agent (Claude Code, Codex)
/// or a shell receives the picture as a file.
extension TerminalPasteboard {
    /// Largest image written for a paste (matches the shipping cmux).
    static let maxClipboardImageBytes = 10 * 1024 * 1024
    static let imageFilenamePrefix = "clipboard-"

    /// Directory for pasted images; one per user, under the temp directory.
    static var imageDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-next-clipboard-images", isDirectory: true)
    }

    /// Whether the pasteboard has an image a paste could deliver.
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// The image on the pasteboard as file bytes and an extension: PNG or
    /// JPEG as is, any other image (TIFF from screenshots) converted to PNG.
    static func imageData(from pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        let png = NSPasteboard.PasteboardType(UTType.png.identifier)
        let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        if let data = pasteboard.data(forType: png), !data.isEmpty { return (data, "png") }
        if let data = pasteboard.data(forType: jpeg), !data.isEmpty { return (data, "jpg") }
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]), !data.isEmpty else { return nil }
        return (data, "png")
    }

    /// Text a paste delivers: the pasteboard's text, or, with no text, the
    /// shell-escaped path of the clipboard image saved to a temporary file.
    static func pasteTextSavingImage(from pasteboard: NSPasteboard, directory: URL = imageDirectory) -> String? {
        if let text = pasteText(from: pasteboard), !text.isEmpty { return text }
        return saveImage(from: pasteboard, directory: directory).map { shellEscaped($0.path) }
    }

    /// Writes the pasteboard's image to `directory`. Nil without an image,
    /// over the size limit, or when the write fails.
    static func saveImage(from pasteboard: NSPasteboard, directory: URL = imageDirectory) -> URL? {
        guard let image = imageData(from: pasteboard), image.data.count <= maxClipboardImageBytes else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(imageFilenamePrefix)\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).\(image.fileExtension)"
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try image.data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }
}
