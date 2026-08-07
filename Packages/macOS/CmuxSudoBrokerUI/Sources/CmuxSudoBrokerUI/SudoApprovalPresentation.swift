public import CmuxSudoBroker
import Foundation
public import Observation

/// Main-actor presentation state for one exact sudo request snapshot.
@MainActor @Observable
public final class SudoApprovalPresentation {
    /// The request metadata shown to the user.
    public let request: SudoRequest

    /// The immutable script reviewed by the user and staged on approval.
    public let script: String

    /// The latest authoritative durable phase.
    public private(set) var phase: SudoRequestPhase

    private var decisionIsPending = false
    @ObservationIgnored private let messages: SudoApprovalViewMessages

    init(
        snapshot: SudoPendingRequest,
        messages: SudoApprovalViewMessages = SudoApprovalViewMessages()
    ) {
        request = snapshot.request
        script = snapshot.script
        phase = snapshot.phase
        self.messages = messages
    }

    var windowTitle: String { messages.windowTitle(requestID: request.id) }
    var heading: String { messages.heading }
    var warning: String { messages.warning }
    var requestIDLabel: String { messages.requestIDLabel }
    var reasonLabel: String { messages.reasonLabel }
    var requesterLabel: String { messages.requesterLabel }
    var workingDirectoryLabel: String { messages.workingDirectoryLabel }
    var queuedLabel: String { messages.queuedLabel }
    var scriptLabel: String { messages.scriptLabel }
    var approveButtonTitle: String { messages.approveButton }
    var denyButtonTitle: String { messages.denyButton }

    var requesterSummary: String {
        messages.requester(
            command: request.requesterCommand,
            processIdentifier: request.requesterPid
        )
    }

    var createdAtSummary: String {
        request.createdAt.formatted(date: .abbreviated, time: .standard)
    }

    var status: String {
        switch phase {
        case .pendingApproval:
            decisionIsPending ? messages.decidingStatus : messages.waitingStatus
        case .approved:
            messages.approvedStatus
        case .executing:
            messages.executingStatus
        }
    }

    var canDecide: Bool {
        phase == .pendingApproval && !decisionIsPending
    }

    var showsProgress: Bool {
        decisionIsPending || phase != .pendingApproval
    }

    func beginDecision() {
        guard phase == .pendingApproval else { return }
        decisionIsPending = true
    }

    func update(phase: SudoRequestPhase) {
        self.phase = phase
        decisionIsPending = phase == .pendingApproval && decisionIsPending
    }
}
