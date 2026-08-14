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
        var unforwardedLocalConfirmations: [PromptLineTurnConfirmation] = []
    }

    /// The latest detector state queued for the notification actor.
    private struct AgentForward: Sendable {
        let agentID: String
        let submissionCount: UInt64
        let revision: UInt64
        let confirmation: PromptLineTurnConfirmation?
        let deadline: ContinuousClock.Instant?
        /// Turns the detector confirmed synchronously at their deadlines, in
        /// identifier order. The notification owner delivers each exactly
        /// once by identifier, so a slow delivery timer cannot lose a
        /// completion and coalescing cannot drop one.
        let locallyConfirmed: [PromptLineTurnConfirmation]
    }

    private struct ForwardQueue {
        var pending: [AgentForward] = []
        var draining = false
    }

    private struct QueuedCapturedLink: Sendable {
        let link: TerminalCapturedLink
        let settings: LinkCaptureSettingsSnapshot
    }

    private struct LinkForwardQueue {
        var pending: [QueuedCapturedLink] = []
        var draining = false
        var released = false
    }

    /// Confirmed turns arrive at most once per confirmation delay, so this
    /// cap can only trim a drain task that has been starved for many
    /// seconds; the newest completions win.
    private static let maximumBufferedLocalConfirmations = 8
    private static let maximumBufferedCapturedLinks = 512

    let workspaceID: UUID
    let surfaceID: UUID
    private let clock = ContinuousClock()
    private let notificationHandler: PromptTurnNotificationHandler
    private var detectors: [DetectorBinding]
    private var linkScanner = TerminalEmittedLinkScanner()
    private var linkScannerNeedsReset = false
    private let forwardQueue = OSAllocatedUnfairLock(initialState: ForwardQueue())
    private let linkForwardQueue = OSAllocatedUnfairLock(initialState: LinkForwardQueue())

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
                    detectors[index].unforwardedLocalConfirmations.append(confirmation)
                }
                detectors[index].confirmationDeadline = nil
            }

            detectors[index].detector.consume(bytes)
            forwardDetectorChangeIfNeeded(at: index, now: now)
        }
    }

    func consumeLinks(
        _ bytes: UnsafeBufferPointer<UInt8>,
        settings: LinkCaptureSettingsSnapshot
    ) {
        guard settings.enabled else {
            noteLinkCaptureDisabled()
            return
        }
        if linkScannerNeedsReset {
            linkScanner.reset()
            linkScannerNeedsReset = false
        }
        let captured = linkScanner.consume(bytes)
        guard !captured.isEmpty else { return }
        enqueueLinks(captured, settings: settings)
    }

    func noteLinkCaptureDisabled() {
        linkScannerNeedsReset = true
    }

    func prepareForRelease() {
        linkForwardQueue.withLock { state in
            state.released = true
            state.pending.removeAll()
        }
    }

    private func forwardDetectorChangeIfNeeded(
        at index: Int,
        now: ContinuousClock.Instant
    ) {
        let revision = detectors[index].detector.confirmationRevision
        let submissionCount = detectors[index].detector.submissionCount
        let locallyConfirmed = detectors[index].unforwardedLocalConfirmations
        guard revision != detectors[index].forwardedRevision ||
            submissionCount != detectors[index].forwardedSubmissionCount ||
            !locallyConfirmed.isEmpty else {
            return
        }
        detectors[index].forwardedRevision = revision
        detectors[index].forwardedSubmissionCount = submissionCount
        detectors[index].unforwardedLocalConfirmations = []

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
                // Coalesce to the latest state but never drop undelivered
                // local confirmations.
                let merged = (state.pending[existing].locallyConfirmed + forward.locallyConfirmed)
                    .suffix(Self.maximumBufferedLocalConfirmations)
                state.pending[existing] = AgentForward(
                    agentID: forward.agentID,
                    submissionCount: forward.submissionCount,
                    revision: forward.revision,
                    confirmation: forward.confirmation,
                    deadline: forward.deadline,
                    locallyConfirmed: Array(merged)
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

    /// Bounds captured-link handoff work and keeps one MainActor drain task in
    /// flight per surface, preserving capture order while avoiding task fanout.
    private func enqueueLinks(
        _ links: [TerminalCapturedLink],
        settings: LinkCaptureSettingsSnapshot
    ) {
        let startDrain = linkForwardQueue.withLock { state in
            guard !state.released else { return false }
            for link in links {
                state.pending.append(QueuedCapturedLink(link: link, settings: settings))
            }
            if state.pending.count > Self.maximumBufferedCapturedLinks {
                state.pending.removeFirst(state.pending.count - Self.maximumBufferedCapturedLinks)
            }
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
        guard startDrain else { return }
        let workspaceID = workspaceID
        let surfaceID = surfaceID
        let linkForwardQueue = linkForwardQueue
        Task {
            while true {
                let next: QueuedCapturedLink? = linkForwardQueue.withLock { state in
                    guard !state.released else {
                        state.pending.removeAll()
                        state.draining = false
                        return nil
                    }
                    guard !state.pending.isEmpty else {
                        state.draining = false
                        return nil
                    }
                    return state.pending.removeFirst()
                }
                guard let next else { return }
                await TerminalLinkCaptureIngress.shared.ingest(
                    [next.link],
                    workspaceID: workspaceID,
                    sourcePanelId: surfaceID,
                    settings: next.settings
                )
            }
        }
    }
}
