/// Resolves `up_…` ids to files C4 received from the same install (seam for
/// C4's upload staging). Throw `MobileDaemonError` `task.attachment_missing`
/// for an id this install did not upload.
public protocol MobileTaskAttachmentResolver: Sendable {
    func resolve(_ uploads: [String], install: String) async throws -> [MobileTaskAttachment]
}

/// The default until C4 registers its staging: every attachment is missing.
public struct UnavailableTaskAttachments: MobileTaskAttachmentResolver {
    public init() {}

    public func resolve(_ uploads: [String], install: String) async throws -> [MobileTaskAttachment] {
        guard uploads.isEmpty else {
            throw MobileDaemonError(code: "task.attachment_missing", message: "attachments are not available on this Mac yet")
        }
        return []
    }
}
