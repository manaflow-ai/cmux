import CmuxTerminalCore
import Foundation
import os

/// Per-surface state owned by libghostty's serialized PTY read callback.
///
/// SAFETY: libghostty invokes a surface's tee callback serially on that
/// surface's IO read thread. After initialization, only that callback mutates
/// `detectors`; other threads receive copied value identifiers after a match.
final class TerminalOutputTeeContext: @unchecked Sendable {
    private struct DetectorBinding {
        let agentID: String
        var detector: PromptLineTurnDetector
        var forwardedRevision: UInt64 = 0
        var forwardedSubmissionCount: UInt64 = 0
        var confirmationDeadline: ContinuousClock.Instant?
        var unforwardedLocalConfirmation: PromptLineTurnConfirmation?
    }

    /// The latest detector state queued for the notification actor.
    private struct AgentForward: Sendable {
        let agentID: String
        let submissionCount: UInt64
        let revision: UInt64
        let confirmation: PromptLineTurnConfirmation?
        let deadline: ContinuousClock.Instant?
        /// A turn the detector confirmed synchronously at its deadline. The
        /// notification owner delivers it exactly once by identifier, so a
        /// slow delivery timer cannot lose the completion.
        let locallyConfirmed: PromptLineTurnConfirmation?
    }

    private struct ForwardQueue {
        var pending: [AgentForward] = []
        var draining = false
    }

    let workspaceID: UUID
    let surfaceID: UUID
    private let clock = ContinuousClock()
    private let notificationHandler: PromptTurnNotificationHandler
    private var detectors: [DetectorBinding]
    private let forwardQueue = OSAllocatedUnfairLock(initialState: ForwardQueue())

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        agentDefinitions: [CmuxTaskManagerCodingAgentDefinition]
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.notificationHandler = PromptTurnNotificationHandler(
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        self.detectors = agentDefinitions.compactMap { definition in
            definition.promptTurnDetection.map {
                DetectorBinding(
                    agentID: definition.id,
                    detector: PromptLineTurnDetector(configuration: $0)
                )
            }
        }
    }

    func consume(_ bytes: UnsafeBufferPointer<UInt8>) {
        let now = clock.now
        for index in detectors.indices {
            if let confirmation = detectors[index].detector.pendingConfirmation,
               let deadline = detectors[index].confirmationDeadline,
               now >= deadline {
                if detectors[index].detector.confirm(confirmation) > 0 {
                    detectors[index].unforwardedLocalConfirmation = confirmation
                }
                detectors[index].confirmationDeadline = nil
            }

            detectors[index].detector.consume(bytes)
            forwardDetectorChangeIfNeeded(at: index, now: now)
        }
    }

    private func forwardDetectorChangeIfNeeded(
        at index: Int,
        now: ContinuousClock.Instant
    ) {
        let revision = detectors[index].detector.confirmationRevision
        let submissionCount = detectors[index].detector.submissionCount
        let locallyConfirmed = detectors[index].unforwardedLocalConfirmation
        guard revision != detectors[index].forwardedRevision ||
            submissionCount != detectors[index].forwardedSubmissionCount ||
            locallyConfirmed != nil else {
            return
        }
        detectors[index].forwardedRevision = revision
        detectors[index].forwardedSubmissionCount = submissionCount
        detectors[index].unforwardedLocalConfirmation = nil

        let confirmation = detectors[index].detector.pendingConfirmation
        let deadline = confirmation.map {
            now.advanced(by: $0.delay)
        }
        detectors[index].confirmationDeadline = deadline
        enqueue(AgentForward(
            agentID: detectors[index].agentID,
            submissionCount: submissionCount,
            revision: revision,
            confirmation: confirmation,
            deadline: deadline,
            locallyConfirmed: locallyConfirmed
        ))
    }

    /// Coalesces to the latest state per agent and keeps at most one drain
    /// task in flight, so sustained PTY output can never fan out unbounded
    /// tasks or queue memory. The single drain task also preserves per-agent
    /// ordering into the notification actor.
    private func enqueue(_ forward: AgentForward) {
        let startDrain = forwardQueue.withLock { state in
            if let existing = state.pending.firstIndex(where: { $0.agentID == forward.agentID }) {
                // Coalesce to the latest state but never drop an undelivered
                // local confirmation.
                state.pending[existing] = AgentForward(
                    agentID: forward.agentID,
                    submissionCount: forward.submissionCount,
                    revision: forward.revision,
                    confirmation: forward.confirmation,
                    deadline: forward.deadline,
                    locallyConfirmed: forward.locallyConfirmed
                        ?? state.pending[existing].locallyConfirmed
                )
            } else {
                state.pending.append(forward)
            }
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        guard startDrain else { return }
        let notificationHandler = notificationHandler
        let forwardQueue = forwardQueue
        Task {
            while true {
                let next: AgentForward? = forwardQueue.withLock { state in
                    guard !state.pending.isEmpty else {
                        state.draining = false
                        return nil
                    }
                    return state.pending.removeFirst()
                }
                guard let next else { return }
                await notificationHandler.update(
                    agentID: next.agentID,
                    submissionCount: next.submissionCount,
                    revision: next.revision,
                    confirmation: next.confirmation,
                    deadline: next.deadline,
                    locallyConfirmed: next.locallyConfirmed
                )
            }
        }
    }
}
