public import CmuxHomeCore
public import CoreGraphics
public import Foundation

/// One attachment of a send from the host's composer.
public struct HomeOutgoingAttachment: @unchecked Sendable {
    public var ref: AttachmentRef
    /// The prepared local files (`HomeStore.prepareAttachment`): the bubble
    /// shows them before the upload ends, and the send uploads them.
    public var files: LocalAttachmentFiles?
    /// The draft thumbnail's frame in viewport points: the morph starts there.
    public var origin: CGRect?
    /// The host's decoded preview: the bubble shows it at once, before any
    /// fetch. `CGImage` is immutable, so sharing it across actors is safe.
    public var preview: CGImage?

    public init(ref: AttachmentRef, files: LocalAttachmentFiles? = nil, origin: CGRect? = nil, preview: CGImage? = nil) {
        self.ref = ref
        self.files = files
        self.origin = origin
        self.preview = preview
    }
}

/// Attachments: where the bytes come from, local files of sends still
/// uploading, and inline video playback.
extension HomeController {
    /// Fetches bubble pictures and video bytes. Until it is set, media
    /// bubbles show their placeholder at their final size.
    public var attachmentLoader: (any HomeAttachmentLoader)? {
        get { scene.media.loader }
        set { scene.media.loader = newValue }
    }

    /// The local files of an attachment that may not be uploaded yet; they
    /// win over the loader.
    public func useLocalFile(_ fileURL: URL, posterURL: URL?, for ref: AttachmentRef) {
        scene.media.useLocalFile(fileURL, poster: posterURL, for: ref.hash)
    }

    /// A picture the host already decoded (a draft thumbnail).
    public func usePreview(_ image: CGImage, for ref: AttachmentRef) {
        scene.media.usePreview(image, for: ref.hash)
    }

    /// Upload progress by content hash (0...1; absent when not uploading),
    /// from `TranscriptItem.attachmentProgress`. Draws a ring on the
    /// bubble; nothing is laid out again.
    public func setUploadProgress(_ progress: [String: Double]) {
        scene.setUploadProgress(progress)
    }

    /// The pending send `intent` as `HomeStore.send` arguments when it
    /// carries attachments whose local files this controller holds.
    func attachmentSend(_ intent: HomeIntent) -> (conversation: ConversationID, text: String, attachments: [LocalAttachment])? {
        guard case .sendMessage(let conversation, let parts) = intent.op else { return nil }
        var attachments: [LocalAttachment] = []
        var text = ""
        for part in parts {
            switch part {
            case .attachment(let ref):
                guard let files = scene.media.localFiles(for: ref.hash) else { return nil }
                attachments.append(LocalAttachment(ref: ref, fileURL: files.file, posterURL: files.poster))
            case .text(let value, _):
                text = value
            default:
                break
            }
        }
        return attachments.isEmpty ? nil : (conversation, text, attachments)
    }

    /// Local files and upload progress the data side attached to items.
    func absorbAttachmentState(_ items: [TranscriptItem]) {
        var progress: [String: Double] = [:]
        for item in items {
            for (hash, files) in item.localAttachments { scene.media.useLocalFile(files.fileURL, poster: files.posterURL, for: hash) }
            progress.merge(item.attachmentProgress) { a, _ in a }
        }
        scene.setUploadProgress(progress)
    }

    /// The playback state of a video part (nil when the part is not a video).
    public func videoState(for item: IdempotencyKey, partIndex: Int) -> HomeVideoState? {
        guard let parts = items.first(where: { $0.key == item })?.parts, parts.indices.contains(partIndex),
              case .attachment(let ref) = parts[partIndex], AttachmentLayout.media(ref)?.isVideo == true else { return nil }
        return scene.video.state("part:\(item.rawValue):\(partIndex)")
    }

    /// Plays or pauses the video under `hit` (a click on its bubble).
    /// Returns false when the part is not a video.
    @discardableResult
    public func toggleVideo(_ hit: HomeHit) -> Bool {
        guard let ref = hit.attachment, AttachmentLayout.media(ref)?.isVideo == true else { return false }
        scene.video.toggle("part:\(hit.item.rawValue):\(hit.partIndex)", ref: ref, media: scene.media)
        return true
    }

    /// Returns when no picture and no video bytes are loading (tests and capture tools).
    public func attachmentsSettled() async {
        await scene.media.settled()
        await scene.video.settled()
        await scene.media.settled()
    }
}

