import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation

#if os(iOS)
/// Starts terminal attachment uploads while the composer is being filled.
///
/// A terminal attachment is always a path typed into the Mac, so it can use the
/// same upload service before Send. Entries are claimed by Send and therefore
/// survive the composer being cleared while the prompt is handed to the PTY.
@MainActor
final class ComposerAttachmentPrestager {
    typealias Upload = @MainActor (LinkUpload.Payload, String) async throws -> String

    struct Entry {
        let task: Task<String, any Error>
        let name: String
        let payloadKey: PayloadKey
        let directory: String?
        let token: UUID
    }

    /// A cheap identity for deciding whether a composer row changed. Comparing
    /// `Data` values here would scan every byte on the main actor.
    enum PayloadKey: Equatable {
        case data(Int)
        case file(URL)
    }

    private(set) var entries: [ComposerAttachment.ID: Entry] = [:]
    private var claimedEntries: [ComposerAttachment.ID: Entry] = [:]

    func sync(_ attachments: [ComposerAttachment], directory: String? = nil, upload: Upload?) {
        let wanted = Set(attachments.map(\.id))
        for (id, entry) in entries where !wanted.contains(id) {
            entry.task.cancel()
            entries[id] = nil
        }

        guard let upload else {
            cancelAll()
            return
        }

        for attachment in attachments where claimedEntries[attachment.id] == nil {
            guard let payload = try? attachment.payload() else { continue }
            let payloadKey: PayloadKey = switch payload {
            case .data(let data): .data(data.count)
            case .file(let url): .file(url)
            }
            if let existing = entries[attachment.id] {
                if existing.name == attachment.name, existing.payloadKey == payloadKey,
                   existing.directory == directory,
                   !existing.task.isCancelled { continue }
                existing.task.cancel()
                entries[attachment.id] = nil
            }
            let token = UUID()
            let task = Task<String, any Error> { @MainActor [weak self] in
                do {
                    let transfer = try await attachment.transferPayload()
                    try Task.checkCancellation()
                    return try await upload(transfer.payload, transfer.name)
                } catch {
                    // A failed pre-send task must not suppress the next retry.
                    if self?.entries[attachment.id]?.token == token {
                        self?.entries[attachment.id] = nil
                    }
                    throw error
                }
            }
            entries[attachment.id] = Entry(task: task, name: attachment.name, payloadKey: payloadKey,
                                           directory: directory, token: token)
        }
    }

    func claim(_ attachments: [ComposerAttachment], directory: String? = nil) -> [ComposerAttachment.ID: Entry] {
        var claimed: [ComposerAttachment.ID: Entry] = [:]
        for attachment in attachments {
            if let entry = entries.removeValue(forKey: attachment.id) {
                if entry.directory == directory {
                    claimed[attachment.id] = entry
                    claimedEntries[attachment.id] = entry
                } else {
                    entry.task.cancel()
                }
            }
        }
        return claimed
    }

    func cancelClaimed() {
        for entry in claimedEntries.values { entry.task.cancel() }
        claimedEntries.removeAll()
    }

    func releaseClaimed() {
        claimedEntries.removeAll()
    }

    func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
        cancelClaimed()
    }

    isolated deinit {
        for entry in entries.values { entry.task.cancel() }
        for entry in claimedEntries.values { entry.task.cancel() }
    }
}

extension ComposerAttachment {
    struct TransferPayload: Sendable {
        let payload: LinkUpload.Payload
        let name: String
    }

    @concurrent
    func transferPayload() async throws -> TransferPayload {
        try Task.checkCancellation()
        if kind == .image {
            let encoded: (data: Data, ext: String)?
            if let data {
                encoded = AttachmentImageEncoder.encode(data)
            } else if let fileURL {
                encoded = AttachmentImageEncoder.encode(fileURL: fileURL, byteCount: byteCount)
            } else {
                encoded = nil
            }
            if let encoded {
                let stem = (name as NSString).deletingPathExtension
                return TransferPayload(payload: .data(encoded.data),
                                       name: "\(stem.isEmpty ? "attachment" : stem).\(encoded.ext)")
            }
        }
        return TransferPayload(payload: try payload(), name: name)
    }
}
#endif
