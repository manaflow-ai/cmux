internal import Foundation

/// Queue-confined cleanup phase plus outstanding local attach-end acknowledgements.
struct RemotePTYSessionLifecycleState: Sendable, Equatable {
    var phase: RemotePTYSessionLifecycle
    private(set) var pendingAttachmentCounts: [String: Int]

    init(
        phase: RemotePTYSessionLifecycle,
        pendingAttachmentCounts: [String: Int] = [:]
    ) {
        self.phase = phase
        self.pendingAttachmentCounts = [:]
        addPendingAttachments(pendingAttachmentCounts)
    }

    var hasPendingAttachments: Bool {
        !pendingAttachmentCounts.isEmpty
    }

    mutating func addPendingAttachments(_ counts: [String: Int]) {
        for (attachmentID, count) in counts where count > 0 {
            pendingAttachmentCounts[Self.normalizedAttachmentID(attachmentID), default: 0] += count
        }
    }

    mutating func acknowledge(attachmentID: String) {
        let normalizedAttachmentID = Self.normalizedAttachmentID(attachmentID)
        guard let count = pendingAttachmentCounts[normalizedAttachmentID] else { return }
        if count > 1 {
            pendingAttachmentCounts[normalizedAttachmentID] = count - 1
        } else {
            pendingAttachmentCounts.removeValue(forKey: normalizedAttachmentID)
        }
    }

    private static func normalizedAttachmentID(_ attachmentID: String) -> String {
        let trimmed = attachmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)?.uuidString ?? trimmed
    }
}
