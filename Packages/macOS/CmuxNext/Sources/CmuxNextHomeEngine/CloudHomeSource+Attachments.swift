public import CmuxHomeCore
import CmuxNextDaemon
public import Foundation

/// Attachments of Cloud conversations (`cloud-attachments-v1`, home-messaging.md
/// section 10.1): the daemon asks the Cloud owner for an upload slot and a
/// signed download URL with its lease and carries the bytes, so photos and
/// videos in Cloud DMs and groups send and show like local ones. Fetched
/// variants land in the same per-hash cache as the local owner's.
nonisolated extension CloudHomeSource {
    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        let (commands, identity, _) = try requireEndpoint()
        let stored = try await reply(for: identity) {
            try await Self.attachmentCall {
                try await commands.uploadAttachment(conversation: file.conversation.rawValue, attachment: HomeCoreMapping.attachment(file.ref),
                                                    file: file.fileURL, posterFile: file.posterURL, previewFile: file.previewURL,
                                                    progress: file.progress)
            }
        }
        return HomeCoreMapping.ref(file.ref, storedAs: stored)
    }

    public func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        try await HomeAttachmentCache(directory: attachmentCache, limit: attachmentCacheLimit).fetch(ref, variant: variant) { piece, target in
            let (commands, identity, _) = try requireEndpoint()
            _ = try await reply(for: identity) {
                try await Self.attachmentCall {
                    try await commands.downloadAttachment(conversation: location.conversation.rawValue, hash: ref.hash, variant: piece,
                                                          to: target)
                }
            }
        }
    }

    /// A daemon without `cloud-attachments-v1` refuses for good (an older
    /// daemon); every other failure is the Cloud reply's (`reply(for:)`).
    private static func attachmentCall<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch DaemonError.missingCapabilities {
            throw HomeRejection.invalid("attachments_unsupported")
        }
    }
}
