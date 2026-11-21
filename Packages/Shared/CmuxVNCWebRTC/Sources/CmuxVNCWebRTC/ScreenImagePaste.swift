import Foundation

// Paste an image from the viewer into the Mac (the phone's Paste Image
// button). The viewer sends the image's bytes as ordered `paste-image`
// messages on the input channel; the Mac puts the image on its pasteboard,
// presses ⌘V and answers with one `paste-image` host message (`ScreenHostMessage.PasteImageOutcome`).
//
// Only a host whose `caps` lists `paste-image` takes it, and never in a
// view-only session. An older host sends no such `caps`, so the viewer
// shows no button for it.
//
// One message: `{"t":"paste-image","id":"…","i":0,"n":12,"f":"public.png","s":"<base64>"}`:
// `id` names the image, `i` is the chunk's index, `n` the chunk count, `f`
// the image's uniform type identifier and `s` the chunk's bytes as base64.
extension ScreenHostMessage {
    /// In the host's `caps`: it takes ``pasteImageType`` messages.
    public static let pasteImageCapability = "paste-image"
    /// `t` of the viewer's image chunks and of the host's answer.
    public static let pasteImageType = "paste-image"

    /// The host's answer to a pasted image, as its `s`.
    public enum PasteImageOutcome: String, Sendable, Equatable {
        /// On the Mac's pasteboard, and ⌘V pressed.
        case pasted
        /// Larger than ``ScreenInput/pasteImageMaximumBytes``, or an unknown type.
        case refused
        /// A chunk went missing (out of order, or another image started).
        case incomplete
    }

    /// The host's answer for `outcome` about the image `id`.
    public init(pasteImage outcome: PasteImageOutcome, id: String?) {
        self.init(t: Self.pasteImageType, s: outcome.rawValue)
        self.id = id
    }

    /// The paste outcome this message carries; nil for any other message.
    public var pasteImageOutcome: PasteImageOutcome? {
        guard t == Self.pasteImageType else { return nil }
        return s.flatMap(PasteImageOutcome.init(rawValue:))
    }
}

extension ScreenInput {
    /// Raw bytes per image chunk: 16 KB as base64, the data channel's message size (`VNCPeerLink.chunk`).
    public static let pasteImageChunkBytes = 12 * 1024
    /// The largest image the host takes (bytes before base64).
    public static let pasteImageMaximumBytes = 20 << 20
    /// The image types the host puts on its pasteboard (uniform type identifiers).
    public static let pasteImageTypes: Set<String> = ["public.png", "public.jpeg", "public.heic", "public.tiff"]

    /// The messages for one image (empty when it is empty, too large or of another type).
    public static func pasteImage(_ data: Data, type: String, id: String = UUID().uuidString) -> [ScreenInput] {
        guard !data.isEmpty, data.count <= pasteImageMaximumBytes, pasteImageTypes.contains(type) else { return [] }
        let count = (data.count + pasteImageChunkBytes - 1) / pasteImageChunkBytes
        return (0 ..< count).map { index in
            let start = data.startIndex + index * pasteImageChunkBytes
            let chunk = data[start ..< min(start + pasteImageChunkBytes, data.endIndex)]
            return ScreenInput(t: ScreenHostMessage.pasteImageType, s: chunk.base64EncodedString(), i: index, n: count, id: id, f: type)
        }
    }
}

/// The host's side of an image paste (`paste-image` messages): collects one image's chunks in
/// order. A chunk out of order, or from another image, drops what it had.
struct ScreenImageAssembler {
    /// What one chunk did.
    enum Step: Equatable {
        /// Kept; more to come.
        case partial
        /// The last chunk: the whole image.
        case complete(Data, type: String, id: String)
        /// Dropped (the answer to send, about the image `id`).
        case failed(ScreenHostMessage.PasteImageOutcome, id: String?)
        /// A later chunk of an image already answered as failed: no second answer.
        case ignored
    }

    private var id: String?
    /// The image that failed: its remaining chunks are ignored, until a new image starts.
    private var failedID: String?
    private var type = ""
    private var expected = 0
    private var count = 0
    private var data = Data()

    mutating func take(_ input: ScreenInput) -> Step {
        if let failedID, input.id == failedID, input.i != 0 { return .ignored }
        guard let id = input.id, let index = input.i, let count = input.n, let type = input.f,
              let chunk = input.s.flatMap({ Data(base64Encoded: $0) }) else { return fail(.incomplete, id: input.id) }
        let maximumChunks = (ScreenInput.pasteImageMaximumBytes + ScreenInput.pasteImageChunkBytes - 1) / ScreenInput.pasteImageChunkBytes
        guard ScreenInput.pasteImageTypes.contains(type), (1 ... maximumChunks).contains(count),
              chunk.count <= ScreenInput.pasteImageChunkBytes else { return fail(.refused, id: id) }
        if index == 0 {
            failedID = nil
            self.id = id
            self.type = type
            self.count = count
            expected = 0
            data = Data()
        }
        guard id == self.id, index == expected, count == self.count, type == self.type else { return fail(.incomplete, id: id) }
        data.append(chunk)
        guard data.count <= ScreenInput.pasteImageMaximumBytes else { return fail(.refused, id: id) }
        expected += 1
        guard expected == count else { return .partial }
        let image = data
        reset()
        return .complete(image, type: type, id: id)
    }

    private mutating func fail(_ outcome: ScreenHostMessage.PasteImageOutcome, id: String?) -> Step {
        reset()
        failedID = id
        return .failed(outcome, id: id)
    }

    private mutating func reset() {
        id = nil
        type = ""
        expected = 0
        count = 0
        data = Data()
    }
}
