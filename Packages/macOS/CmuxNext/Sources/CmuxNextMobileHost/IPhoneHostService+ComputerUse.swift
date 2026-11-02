public import Foundation
public import CmuxNextMobile

/// Computer Use app approvals on the owner's iPhone (docs/computer-use-approvals.md, "Phone
/// wire"): the question goes to hostd, which pushes it to the paired phones; a phone's Face ID
/// signed answer comes back on ``computerUseAnswers``. The approval keys the app checks those
/// answers with are this Mac's own paired list, never hostd's word.
extension IPhoneHostService {
    /// Pushes a question to the paired phones (and again to a restarted hostd while it is open).
    public func computerUseAsk(digest: String, request: [String: Any], always: Bool) {
        let line = MobileHostLaunch.computerUseApprovalLine(request: request, always: always)
        let supervisor = supervisor
        // task-owner: one hop to the supervisor actor; it keeps the line for a restarted hostd.
        Task { await supervisor.computerUseAsk(digest: digest, line: line) }
    }

    /// The question `digest` is settled or gone.
    public func computerUseDone(digest: String) {
        let supervisor = supervisor
        // task-owner: one hop to the supervisor actor; a digest it does not hold is a no-op.
        Task { await supervisor.computerUseDone(digest: digest) }
    }

    /// Phones' answers, in order (one reader).
    public var computerUseAnswers: AsyncStream<MobileHostComputerUseAnswer> { supervisor.computerUseAnswers }

    /// The approval key (X9.63 hex) of a phone this Mac's person paired, by link device id.
    public func computerUseApprovalKey(phoneDeviceID: String) -> String? {
        paired?.devices.first { $0.id == phoneDeviceID }?.approvalKey
    }
}
