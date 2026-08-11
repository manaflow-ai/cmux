#if os(iOS) && DEBUG
import CmuxMobileSupport
import Observation

/// A deliberately cancellation-resistant provider for verifying generation guards.
@MainActor
@Observable
final class MobileAttachmentPreparationAccessibilityFixture {
    enum Phase: String {
        case starting
        case waiting
        case returned
    }

    private let attachment: MobileStagedAttachment
    private var continuation: CheckedContinuation<MobileStagedAttachment?, Never>?
    private var completed = false
    private(set) var phase: Phase = .starting

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
                self.phase = .waiting
            }
        }
        phase = .returned
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
