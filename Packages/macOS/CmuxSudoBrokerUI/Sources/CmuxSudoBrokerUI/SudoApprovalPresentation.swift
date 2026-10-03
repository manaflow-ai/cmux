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
    @ObservationIgnored private let scriptAnnotation: SudoInvisibleTextAnnotator.Annotation
    @ObservationIgnored private let metadataAnnotations: [SudoInvisibleTextAnnotator.Annotation]

    init(
        snapshot: SudoPendingRequest,
        messages: SudoApprovalViewMessages = SudoApprovalViewMessages(),
        annotator: SudoInvisibleTextAnnotator = SudoInvisibleTextAnnotator()
    ) {
        request = snapshot.request
        script = snapshot.script
        phase = snapshot.phase
        self.messages = messages
        // Annotations are display copies only; `script` stays byte-identical to the
        // reviewed snapshot that the broker stages and binds by digest.
        scriptAnnotation = annotator.annotate(snapshot.script)
        metadataAnnotations = [
            snapshot.request.id,
            snapshot.request.reason,
            snapshot.request.requesterCommand,
            snapshot.request.currentDirectory,
        ].map(annotator.annotate)
    }

    /// The script with hidden and direction-changing characters rendered as visible markers.
    var displayScript: String { scriptAnnotation.display }
    var displayRequestID: String { metadataAnnotations[0].display }
    var displayReason: String { metadataAnnotations[1].display }
    var displayWorkingDirectory: String { metadataAnnotations[3].display }

    /// The number of hidden characters across the script and request metadata.
    var hiddenCharacterCount: Int {
        scriptAnnotation.hiddenCharacterCount
            + metadataAnnotations.reduce(0) { $0 + $1.hiddenCharacterCount }
    }

    var containsHiddenCharacters: Bool { hiddenCharacterCount > 0 }

    var hiddenCharacterWarning: String {
        messages.hiddenCharacterWarning(count: hiddenCharacterCount)
    }

    var hiddenCharacterBadge: String { messages.hiddenCharacterBadge }

    var windowTitle: String { messages.windowTitle(requestID: displayRequestID) }
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
            command: metadataAnnotations[2].display,
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

    /// Applies the broker's answer to the decision started by ``beginDecision()``.
    ///
    /// A decided request keeps showing progress until the authoritative snapshot
    /// advances or dismisses it. A request the broker left pending (for example
    /// because its result could not be persisted) becomes decidable again.
    func finishDecision(_ outcome: SudoDecisionOutcome) {
        guard outcome == .stillPending else { return }
        decisionIsPending = false
    }
}
