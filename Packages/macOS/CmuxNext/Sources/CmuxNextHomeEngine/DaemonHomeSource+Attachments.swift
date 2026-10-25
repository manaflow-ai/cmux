public import CmuxHomeCore
import CmuxNextDaemon
public import Foundation

/// Attachments on the local conversation owner (`local-attachments-v1`):
/// uploads go to the daemon by SHA-256, and fetched variants land in a
/// cache file per hash and variant (`HomeAttachmentCache`, which also
/// downsamples thumbnails: the daemon has no thumbnail service).
nonisolated extension DaemonHomeSource {
    /// `~/Library/Caches/<bundle id>/HomeAttachments`.
    public static var defaultAttachmentCache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
            .appendingPathComponent("HomeAttachments", isDirectory: true)
    }

    /// 512 MB: a few hundred photos; the owner keeps every byte, so an
    /// evicted file costs one more read.
    public static var defaultAttachmentCacheLimit: Int { 512_000_000 }

    /// The local owner takes `link_preview` parts when it advertises
    /// `link-preview-v1` (a daemon older than the part gets plain text).
    public func acceptsLinkPreviews(in conversation: ConversationID) async -> Bool {
        guard let connection = try? requireOwner() else { return false }
        return await connection.identity?.supports(DaemonCapability.linkPreview.rawValue) == true
    }

    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        let connection = try requireOwner()
        let stored = try await Self.attachmentCall {
            try await ConversationClient(connection)
                .uploadAttachment(conversation: file.conversation.rawValue, attachment: HomeCoreMapping.attachment(file.ref),
                                  file: file.fileURL, posterFile: file.posterURL, previewFile: file.previewURL,
                                  progress: file.progress)
        }
        return HomeCoreMapping.ref(file.ref, storedAs: stored)
    }

    public func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        try await HomeAttachmentCache(directory: attachmentCache, limit: attachmentCacheLimit).fetch(ref, variant: variant) { piece, target in
            _ = try await Self.attachmentCall {
                try await ConversationClient(self.requireConnection())
                    .downloadAttachment(conversation: location.conversation.rawValue, hash: ref.hash, variant: piece, to: target)
            }
        }
    }

    /// `mapped`, plus a local daemon without attachments as a final refusal.
    private static func attachmentCall<T>(_ body: () async throws -> T) async throws -> T {
        try await mapped {
            do {
                return try await body()
            } catch DaemonError.missingCapabilities {
                throw HomeRejection.invalid("attachments_unsupported")
            }
        }
    }
}
