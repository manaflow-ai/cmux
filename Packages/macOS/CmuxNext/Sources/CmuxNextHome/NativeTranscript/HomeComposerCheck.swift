import CmuxHomeCore
import Foundation
import UniformTypeIdentifiers

/// The composer's check before preparing, with the data side's own rule
/// (`HomeAttachmentPolicy.accepts`, which knows what it converts) for the
/// type and the owner's limits for the size, so paste, drop, the drag check
/// and the picker agree and a refused file is never hashed or copied.
enum HomeComposerCheck {
    /// The types the file picker offers: exactly what the data side accepts.
    static var pickerTypes: [UTType] {
        HomeAttachmentPolicy.acceptedInputTypes.sorted().compactMap { UTType($0) }
    }

    /// Whether the data side takes a file of this URL's type.
    static func accepts(_ url: URL) -> Bool { HomeAttachmentPolicy.accepts(fileURL: url) }

    /// Nil when the input may be attached, else the notice that says why not.
    static func refusal(for input: HomeDraftInput) -> String? {
        let name: String, accepted: Bool, size: Int, typeName: String
        switch input {
        case .file(let url):
            // A stat for the size only; the bytes are read by the data side.
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            name = url.lastPathComponent
            accepted = accepts(url)
            size = values?.fileSize ?? 0
            typeName = url.pathExtension
        case .data(let data, let identifier):
            name = HomeStrings.pastedItem
            accepted = HomeAttachmentPolicy.accepts(typeIdentifier: identifier)
            size = data.count
            typeName = identifier
        }
        guard accepted else { return HomeStrings.attachmentRefusal(.typeRefused(mimeType: typeName, name: name), name: name) }
        if size > HomeAttachmentPolicy.maxBytes {
            return HomeStrings.attachmentRefusal(.tooLarge(byteCount: size, limit: HomeAttachmentPolicy.maxBytes), name: name)
        }
        if size == 0 { return HomeStrings.attachmentRefusal(.empty(name: name), name: name) }
        return nil
    }
}
