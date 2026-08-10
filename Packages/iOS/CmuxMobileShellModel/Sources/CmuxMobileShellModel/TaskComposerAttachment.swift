public import CmuxMobileSupport

/// Compatibility name for the shared staged-attachment value.
public typealias TaskComposerAttachment = MobileStagedAttachment

public extension MobileStagedAttachment {
    /// Value-only identity captured by a task submission snapshot.
    var submissionAttachment: MobileTaskSubmissionAttachment {
        MobileTaskSubmissionAttachment(uploadID: id, byteCount: byteCount)
    }
}
