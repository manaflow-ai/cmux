#if DEBUG
import CmuxFoundation
import Foundation

/// Identifies one admitted window-screenshot capture and its compositor policy.
struct WindowScreenshotCaptureAdmission: Sendable, Equatable {
    let id: UUID
    let allowsScreenCaptureKit: Bool
    let coordinatorID: UUID
    private let retirementIsAvailable: AtomicBooleanGate

    init(id: UUID, allowsScreenCaptureKit: Bool, coordinatorID: UUID) {
        self.id = id
        self.allowsScreenCaptureKit = allowsScreenCaptureKit
        self.coordinatorID = coordinatorID
        self.retirementIsAvailable = AtomicBooleanGate(true)
    }

    func claimRetirement() -> Bool {
        retirementIsAvailable.compareExchange(expected: true, desired: false)
    }

    static func == (
        lhs: WindowScreenshotCaptureAdmission,
        rhs: WindowScreenshotCaptureAdmission
    ) -> Bool {
        lhs.id == rhs.id &&
            lhs.allowsScreenCaptureKit == rhs.allowsScreenCaptureKit &&
            lhs.coordinatorID == rhs.coordinatorID
    }
}
#endif
