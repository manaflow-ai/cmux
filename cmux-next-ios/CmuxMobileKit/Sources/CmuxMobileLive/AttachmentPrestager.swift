import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import OSLog

/// Uploads a chat's attached files to the Mac the moment they are picked, before Send (Leo:
/// "attachments and shit potentially need to be optimistically transferred from phone to mac").
/// Send then links the copy already on the Mac instead of starting the upload: a file picked
/// while the message is typed is there, or partway there, when Send is tapped.
///
/// Only what a prompt would upload goes early: a file that is not an inline image or an inline
/// PDF (those travel in the prompt itself). A file taken off the composer before Send cancels
/// its upload; one that is sent is handed to its prompt (``claim(_:)``), which waits for it and
/// uploads afresh if the early upload failed.
@MainActor
final class AttachmentPrestager {
    enum Result: Sendable, Equatable {
        case path(String)
        case prompt(uploadID: String, fileName: String, ownerToken: String?)
    }

    typealias Upload = @Sendable (LinkUpload.Payload, String) async throws -> Result

    static let log = Logger(subsystem: "dev.cmux.mobile", category: "upload")

    /// An early upload: its task and when the file was picked.
    struct Signature: Equatable {
        let kind: AgentAttachment.Kind
        let name: String
        let byteCount: Int?
        let dataCount: Int?
        let fileURL: URL?
        let head: Data
        let tail: Data
    }

    struct Entry {
        let task: Task<Result, any Error>
        let started: ContinuousClock.Instant
        let directory: String?
        let signature: Signature
        let token: UUID
    }

    private(set) var entries: [String: Entry] = [:]

    /// Whether `attachment` goes to the Mac by upload when sent (``AcpmuxSessionSource/promptBlocks``'s
    /// rule): not an image the prompt carries, not a PDF small enough to go inline, and with bytes here.
    nonisolated static func uploadsAtSend(_ attachment: AgentAttachment, promptUploads: Bool = false) -> Bool {
        if attachment.kind == .image {
            guard promptUploads || attachment.imageMIMEType == nil || attachment.data == nil
                || (attachment.data?.count ?? attachment.byteCount ?? 0) > inlineImageBytes else { return false }
            return attachment.data != nil || attachment.fileURL != nil
        }
        guard attachment.data != nil || attachment.fileURL != nil else { return false }
        if attachment.isPDF, (attachment.byteCount ?? attachment.data?.count ?? .max) <= AgentAttachment.maxDocumentBytes {
            return false
        }
        return true
    }

    /// The composer's attachments now: starts an upload for each new one that would upload at
    /// send, cancels the uploads of those taken off. `upload` nil (no link): nothing starts.
    func sync(_ attachments: [AgentAttachment], directory: String? = nil, upload: Upload?, promptUploads: Bool = false) {
        let wanted = Set(attachments.filter { Self.uploadsAtSend($0, promptUploads: promptUploads) }.map(\.id))
        for (id, entry) in entries where !wanted.contains(id) || entry.directory != directory
            || !attachments.contains(where: { $0.id == id && Self.signature($0) == entry.signature }) {
            entry.task.cancel()
            entries[id] = nil
        }
        guard let upload else {
            cancelAll()
            return
        }
        for attachment in attachments where wanted.contains(attachment.id) && entries[attachment.id] == nil {
            let payload: LinkUpload.Payload
            if let data = attachment.data { payload = .data(data) } else if let url = attachment.fileURL { payload = .file(url) } else { continue }
            let name = attachment.name
            let bytes = attachment.byteCount ?? attachment.data?.count ?? 0
            let started = ContinuousClock.now
            let signature = Self.signature(attachment)
            let token = UUID()
            let task = Task<Result, any Error> { [weak self] in
                do {
                    let result = try await upload(payload, name)
                    Self.log.info("prestage ms=\(Self.ms(ContinuousClock.now - started)) bytes=\(bytes) ok=true")
                    return result
                } catch {
                    await self?.removeFailed(id: attachment.id, token: token)
                    Self.log.info("prestage ms=\(Self.ms(ContinuousClock.now - started)) bytes=\(bytes) ok=false")
                    throw error
                }
            }
            entries[attachment.id] = Entry(task: task, started: started, directory: directory,
                                           signature: signature, token: token)
        }
    }

    private func removeFailed(id: String, token: UUID) {
        guard entries[id]?.token == token else { return }
        entries[id] = nil
    }

    /// Hands the early uploads of a sent prompt's attachments to it: no later ``sync(_:upload:)``
    /// (the composer emptied by Send) cancels them.
    func claim(_ attachments: [AgentAttachment], directory: String? = nil) -> [String: Entry] {
        var claimed: [String: Entry] = [:]
        for attachment in attachments {
            guard let entry = entries.removeValue(forKey: attachment.id) else { continue }
            if entry.directory == directory {
                claimed[attachment.id] = entry
            } else {
                entry.task.cancel()
            }
        }
        return claimed
    }

    /// Cancels composer uploads that belong to a link which is no longer usable. The source
    /// keeps the desired attachment list and starts these again when the next link is ready.
    func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }

    /// The chat went away with files still on its composer: their uploads have no owner.
    isolated deinit {
        for entry in entries.values { entry.task.cancel() }
    }

    nonisolated static func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    /// Keep identity checks bounded. Hashing an attachment's full Data on the main actor would
    /// turn a large photo change into another transfer-sized pause.
    nonisolated static func signature(_ attachment: AgentAttachment) -> Signature {
        let data = attachment.data
        return Signature(kind: attachment.kind, name: attachment.name, byteCount: attachment.byteCount, dataCount: data?.count,
                         fileURL: attachment.fileURL, head: Data(data?.prefix(32) ?? []),
                         tail: Data(data?.suffix(32) ?? []))
    }

    /// The daemon's inline image cap is 3.75 MiB decoded. Larger images use a file reference on
    /// older Macs, while newer Macs upload every image as a prompt-owned reference.
    nonisolated static let inlineImageBytes = (5 << 20) / 4 * 3
}
