import AppKit

/// cmux: the attachment a press landed on, for its drag out of Home.
struct HomeAttachmentDragRequest {
    /// The attachment's name (the dropped file's name).
    var name: String
    /// Its message and attachment ids (``ChatIntents/attachmentFile(_:_:)``).
    var message: ID
    var attachment: ID
    /// The bubble, in the host's coordinates (where the drag image starts).
    var frame: CGRect
    /// Its local copy when the press already fetched it; nil: the drag promises the file.
    var file: URL?
}

/// cmux: an attachment dragged out of the transcript (the user, 2026-10-21: "i need to be able to
/// drag it out to other apps too"). The press fetches the local copy at once, so the drag that
/// follows usually carries the file itself; otherwise it is a file promise (``HomeAttachmentDrag``).
extension ChatController {
    /// A press on attachment `a`: remembers it for a drag and starts fetching its local copy.
    func pressAttachment(_ a: Attachment, message: ID, frame: CGRect, at p: CGPoint) {
        attachmentPress = (HomeAttachmentDragRequest(name: a.fileName, message: message, attachment: a.id, frame: frame), p)
        if attachmentPressFile?.attachment == a.id { return }
        attachmentPrefetch?.cancel()
        attachmentPressFile = nil
        guard let intents else { return }
        let id = a.id
        // task-owner: one fetch of the pressed attachment; replaced by the next press on another one
        attachmentPrefetch = Task { @MainActor [weak self] in
            guard let file = await intents.attachmentFile(message, id), !Task.isCancelled else { return }
            self?.attachmentPressFile = (id, file)
        }
    }

    /// The real drag: a dragging session on the host with the file (or its promise) and a preview.
    func startAttachmentDrag(_ request: HomeAttachmentDragRequest, _ event: NSEvent) {
        let message = request.message, attachment = request.attachment
        let drag = HomeAttachmentDrag(name: request.name) { [weak self] in
            await self?.intents?.attachmentFile(message, attachment)
        }
        attachmentDragSource = drag
        let item = NSDraggingItem(pasteboardWriter: drag.writer(file: request.file))
        let image = drag.preview(file: request.file, size: request.frame.size)
        let frame = CGRect(x: request.frame.midX - image.size.width / 2, y: request.frame.midY - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
        item.setDraggingFrame(frame, contents: image)
        let session = host.beginDraggingSession(with: [item], event: event, source: drag)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}
