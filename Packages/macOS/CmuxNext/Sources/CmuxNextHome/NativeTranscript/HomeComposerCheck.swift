import CmuxHomeCore
import Foundation
import UniformTypeIdentifiers

/// The composer's check before preparing: the owner's allow list and size
/// limit (`HomeAttachmentPolicy` in CmuxHomeCore) applied to the file's
/// type and size, so a refused file is never hashed or copied.
enum HomeComposerCheck {
    /// Nil when the input may be attached, else the notice that says why not.
    static func refusal(for input: HomeDraftInput) -> String? {
        let name: String, type: UTType?, size: Int
        switch input {
        case .file(let url):
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            name = url.lastPathComponent
            type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            size = values?.fileSize ?? 0
        case .data(let data, let identifier):
            name = HomeStrings.pastedItem
            type = UTType(identifier)
            size = data.count
        }
        do {
            try HomeAttachmentPolicy.check(mimeType: type?.preferredMIMEType ?? "application/octet-stream", byteCount: size, name: name)
            return nil
        } catch let refusal as HomeAttachmentError {
            return HomeStrings.attachmentRefusal(refusal, name: name)
        } catch {
            return HomeStrings.attachFailed
        }
    }
}
