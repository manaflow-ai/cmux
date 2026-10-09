import Foundation
import UniformTypeIdentifiers

/// MIME type from a file name's extension.
struct FileMime {
    let name: String

    var value: String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }
}
