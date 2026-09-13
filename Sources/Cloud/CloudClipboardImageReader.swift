import Darwin
import Foundation

/// Keeps filesystem reads and image validation off the main actor.
actor CloudClipboardImageReader {
    func read(_ url: URL) throws -> CloudClipboardImage {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CloudImagePasteError.unsupportedType }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CloudImagePasteError.storage }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw CloudImagePasteError.unsupportedType
        }
        guard metadata.st_size >= 0, metadata.st_size <= Int64(CloudClipboardImage.maximumBytes) else {
            throw CloudImagePasteError.sizeLimit
        }
        let data: Data
        do {
            data = try file.read(upToCount: CloudClipboardImage.maximumBytes + 1) ?? Data()
        } catch {
            throw CloudImagePasteError.storage
        }
        try Task.checkCancellation()
        return try CloudClipboardImage(data: data)
    }
}
