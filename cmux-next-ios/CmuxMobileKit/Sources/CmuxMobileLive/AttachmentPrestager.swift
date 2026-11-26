import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import OSLog

/// Uploads a chat's attached files to the Mac the moment they are picked, before Send (Leo:
/// "attachments and shit potentially need to be optimistically transferred from phone to mac").
/// Send then links the copy already on the Mac instead of starting the upload: a file picked
/// while the message is typed is there, or partway there, when Send is tapped.
///
/// A Mac with prompt upload support can receive prepared photos before Send. Other files use
/// the same Mac link as a normal send. Removing a file cancels its transfer. Sending claims
/// the transfer so clearing the composer leaves the prompt in control of it.
@MainActor
final class AttachmentPrestager {
    enum Result: Sendable, Equatable {
        case path(String)
        case prompt(uploadID: String, fileName: String, ownerToken: String?)
    }

    typealias Report = @MainActor @Sendable (AgentUploadProgress) -> Void
    typealias Upload = @Sendable (LinkUpload.Payload, AgentAttachment, @escaping Report) async throws -> Result

    @MainActor
    final class Progress {
        private var observer: Report?
        private var latest: AgentUploadProgress?

        func update(_ step: AgentUploadProgress) {
            latest = step
            observer?(step)
        }

        func observe(_ report: @escaping Report) {
            observer = report
            if let latest { report(latest) }
        }
    }

    static let log = Logger(subsystem: "dev.cmux.mobile", category: "upload")

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
        let progress: Progress
        let discard: (@Sendable (Result) async -> Void)?
        let directory: String?
        let signature: Signature
        let token: UUID

        func cancel() {
            task.cancel()
            if let discard {
                Task {
                    if let result = try? await task.value { await discard(result) }
                }
            }
        }
    }

    private(set) var entries: [String: Entry] = [:]

    /// Whether `attachment` goes to the Mac by upload when sent (``AcpmuxSessionSource/promptBlocks``'s
    /// rule), given the connected Mac's support for image references.
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
    func sync(_ attachments: [AgentAttachment], directory: String? = nil, upload: Upload?, promptUploads: Bool = false,
              discard: (@Sendable (Result) async -> Void)? = nil) {
        let wanted = Set(attachments.filter { Self.uploadsAtSend($0, promptUploads: promptUploads) }.map(\.id))
        for (id, entry) in entries where !wanted.contains(id) || entry.directory != directory
            || !attachments.contains(where: { $0.id == id && Self.signature($0) == entry.signature }) {
            entry.cancel()
            entries[id] = nil
        }
        guard let upload else {
            cancelAll()
            return
        }
        for attachment in attachments where wanted.contains(attachment.id) && entries[attachment.id] == nil {
            let payload: LinkUpload.Payload
            if let data = attachment.data { payload = .data(data) } else if let url = attachment.fileURL { payload = .file(url) } else { continue }
            let bytes = attachment.byteCount ?? attachment.data?.count ?? 0
            let started = ContinuousClock.now
            let signature = Self.signature(attachment)
            let token = UUID()
            let progress = Progress()
            let task = Task<Result, any Error> { [weak self] in
                do {
                    let result = try await upload(payload, attachment) { progress.update($0) }
                    Self.log.info("prestage ms=\(Self.ms(ContinuousClock.now - started)) bytes=\(bytes) ok=true")
                    return result
                } catch {
                    self?.removeFailed(id: attachment.id, token: token)
                    Self.log.info("prestage ms=\(Self.ms(ContinuousClock.now - started)) bytes=\(bytes) ok=false")
                    throw error
                }
            }

            entries[attachment.id] = Entry(task: task, started: started, progress: progress, discard: discard, directory: directory,
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
            if entry.directory == directory && entry.signature == Self.signature(attachment) {
                claimed[attachment.id] = entry
            } else {
                entry.cancel()
            }
        }
        return claimed
    }

    /// Cancels all uploads owned by the current link before a reconnect creates new ones.
    func cancelAll() {
        for entry in entries.values { entry.cancel() }
        entries.removeAll()
    }

    /// The chat went away with files still on its composer: their uploads have no owner.
    isolated deinit {
        for entry in entries.values { entry.cancel() }
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
