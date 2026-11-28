import Foundation

/// The `paste-image` messages of one image, made one at a time as they are read: each chunk's
/// base64 exists only while its message is being sent (``ScreenInput/pasteImageChunks(_:type:id:)``).
public struct PasteImageChunks: Sequence, Sendable {
    /// The image's bytes.
    public let data: Data
    /// The image's uniform type identifier.
    public let type: String
    /// The id every chunk names.
    public let id: String

    /// How many chunks the image takes.
    public var count: Int { (data.count + ScreenInput.pasteImageChunkBytes - 1) / ScreenInput.pasteImageChunkBytes }

    /// Makes chunk messages in order, one per `next()`.
    public struct Iterator: IteratorProtocol {
        let chunks: PasteImageChunks
        var index = 0

        public mutating func next() -> ScreenInput? {
            guard index < chunks.count else { return nil }
            defer { index += 1 }
            let data = chunks.data
            let start = data.startIndex + index * ScreenInput.pasteImageChunkBytes
            let chunk = data[start ..< Swift.min(start + ScreenInput.pasteImageChunkBytes, data.endIndex)]
            return ScreenInput(t: ScreenHostMessage.pasteImageType, s: chunk.base64EncodedString(), i: index, n: chunks.count,
                               id: chunks.id, f: chunks.type)
        }
    }

    public func makeIterator() -> Iterator { Iterator(chunks: self) }
}
