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
        let payload: LinkUpload.Payload
    }

    private(set) var entries: [ComposerAttachment.ID: Entry] = [:]
    private var claimedEntries: [ComposerAttachment.ID: Entry] = [:]

    func sync(_ attachments: [ComposerAttachment], upload: Upload?) {
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
            if let existing = entries[attachment.id] {
                if existing.name == attachment.name, existing.payload == payload { continue }
                existing.task.cancel()
                entries[attachment.id] = nil
            }
            let task = Task<String, any Error> { @MainActor in
                let transfer = try await attachment.transferPayload()
                try Task.checkCancellation()
                return try await upload(transfer.payload, transfer.name)
            }
            entries[attachment.id] = Entry(task: task, name: attachment.name, payload: payload)
        }
    }

    func claim(_ attachments: [ComposerAttachment]) -> [ComposerAttachment.ID: Entry] {
        var claimed: [ComposerAttachment.ID: Entry] = [:]
        for attachment in attachments {
            if let entry = entries.removeValue(forKey: attachment.id) {
                claimed[attachment.id] = entry
                claimedEntries[attachment.id] = entry
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
        guard kind == .image, let data, let encoded = AttachmentImageEncoder.encode(data) else {
            return TransferPayload(payload: try payload(), name: name)
        }
        let stem = (name as NSString).deletingPathExtension
        return TransferPayload(payload: .data(encoded.data), name: "\(stem.isEmpty ? "attachment" : stem).\(encoded.ext)")
    }
}
#endif
