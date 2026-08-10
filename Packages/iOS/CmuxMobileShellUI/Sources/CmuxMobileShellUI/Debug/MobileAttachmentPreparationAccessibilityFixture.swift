#if os(iOS) && DEBUG
import CmuxMobileSupport
import Observation

/// A deliberately cancellation-resistant provider for verifying generation guards.
@MainActor
@Observable
final class MobileAttachmentPreparationAccessibilityFixture {
    private let attachment: MobileStagedAttachment
    private var continuation: CheckedContinuation<MobileStagedAttachment?, Never>?
    private var completed = false
    private(set) var didReturn = false

    init(attachment: MobileStagedAttachment) {
        self.attachment = attachment
    }

    func prepare() async -> MobileStagedAttachment? {
        let result: MobileStagedAttachment?
        if completed {
            result = attachment
        } else {
            result = await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        didReturn = true
        return result
    }

    func complete() {
        guard !completed else { return }
        completed = true
        continuation?.resume(returning: attachment)
        continuation = nil
    }
}
#endif
