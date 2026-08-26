import CmuxTerminalCore
import CmuxWorkspaces
import Foundation
import os

/// Per-surface state owned by libghostty's serialized PTY read callback.
///
/// SAFETY: libghostty invokes a surface's tee callback serially on that
/// surface's IO read thread. After initialization, only that callback mutates
/// `detectors` and `contextPressureDetectors`; other threads receive copied
/// value identifiers after a match.
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
        var contextPressurePending: TerminalContextPressureForward?
        var contextPressureDraining = false
        var contextPressureResetGeneration: UInt64?
        var contextPressureDetectorResetRequested = false
        var contextPressureMonitoringEnabled = false
        var contextPressureMonitoringGeneration: UInt64 = 0
    }

    /// Confirmed turns arrive at most once per confirmation delay, so this
    /// cap can only trim a drain task that has been starved for many
    /// seconds; the newest completions win.
    private static let maximumBufferedLocalConfirmations = 8

    let workspaceID: UUID
    let surfaceID: UUID
    private let clock = ContinuousClock()
    private let notificationHandler: PromptTurnNotificationHandler
    private var detectors: [DetectorBinding]
    private var contextPressureDetectors: [AgentContextProvider: AgentContextPressureDetector]
    private var contextPressureGeneration: UInt64
    private let contextPressureHandler: (@MainActor @Sendable (UUID, UUID, UInt64, [AgentContextPressureEvent]) -> Void)?
    private let forwardQueue = OSAllocatedUnfairLock(initialState: ForwardQueue())
    // Lock carve-out: the PTY callback is synchronous and cannot await an
    // actor, so these bounded control edges are the smallest safe handoff;
    // the serialized callback remains the sole owner of detector mutation.

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        agentDefinitions: [CmuxTaskManagerCodingAgentDefinition],
        contextPressureGeneration: UInt64 = 0,
        contextPressureMonitoringEnabled: Bool = false,
        contextPressureHandler: (@MainActor @Sendable (UUID, UUID, UInt64, [AgentContextPressureEvent]) -> Void)? = nil
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
        self.contextPressureHandler = contextPressureHandler
        self.contextPressureGeneration = contextPressureGeneration
        if contextPressureMonitoringEnabled {
            forwardQueue.withLock { $0.contextPressureMonitoringEnabled = true }
        }
        self.contextPressureDetectors = Dictionary(uniqueKeysWithValues: AgentContextProvider.allCases.map { provider in
            (provider, AgentContextPressureDetector(provider: provider))
        })
    }

    /// Publishes a reset edge for the serialized PTY callback to consume.
    ///
    /// The callback may be running on libghostty's IO thread while the
    /// recovery coordinator runs on the main actor, so parser state is reset
    /// at the next callback boundary rather than being mutated concurrently.
    func requestContextPressureReset(to generation: UInt64) {
        forwardQueue.withLock { queue in
            queue.contextPressureResetGeneration = max(
                queue.contextPressureResetGeneration ?? 0,
                generation
            )
            // Do not coalesce pre-reset evidence into a newer detector generation.
            queue.contextPressurePending = nil
        }
    }

    /// Updates the eligibility gate read by the serialized PTY callback.
    func setContextPressureMonitoringEnabled(_ enabled: Bool) {
        forwardQueue.withLock { state in
            guard state.contextPressureMonitoringEnabled != enabled else { return }
            state.contextPressureMonitoringEnabled = enabled
            state.contextPressureMonitoringGeneration &+= 1
            // The serialized callback performs the reset before it parses the
            // first byte from the new eligibility interval.
            state.contextPressureDetectorResetRequested = true
            // A queued event belongs to the previous eligibility interval and
            // must not cross disable, re-enable, or binding replacement.
            state.contextPressurePending = nil
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
        let control = forwardQueue.withLock { state in
            let snapshot = (
                resetGeneration: state.contextPressureResetGeneration,
                detectorResetRequested: state.contextPressureDetectorResetRequested,
                monitoringEnabled: state.contextPressureMonitoringEnabled,
                monitoringGeneration: state.contextPressureMonitoringGeneration
            )
            state.contextPressureResetGeneration = nil
            state.contextPressureDetectorResetRequested = false
            return snapshot
        }
        let advancesDetectorGeneration = control.resetGeneration.map {
            $0 > contextPressureGeneration
        } ?? false
        if control.detectorResetRequested || advancesDetectorGeneration {
            for provider in AgentContextProvider.allCases {
                contextPressureDetectors[provider]?.reset()
            }
        }
        if let requestedGeneration = control.resetGeneration,
           requestedGeneration > contextPressureGeneration {
            contextPressureGeneration = requestedGeneration
        }
        guard control.monitoringEnabled, contextPressureHandler != nil else { return }
        let output = String(decoding: bytes, as: UTF8.self)
        guard !output.isEmpty else { return }
        var eventsToDeliver: [AgentContextPressureEvent] = []
        for provider in AgentContextProvider.allCases {
            guard var detector = contextPressureDetectors[provider] else { continue }
            let events = detector.consume(output)
            contextPressureDetectors[provider] = detector
            eventsToDeliver.append(contentsOf: events)
        }
        if !eventsToDeliver.isEmpty {
            enqueueContextPressure(
                workspaceID,
                surfaceID,
                contextPressureGeneration,
                control.monitoringGeneration,
                eventsToDeliver
            )
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

    /// Coalesces pressure events and keeps one async delivery task per surface.
    /// The PTY callback can outpace the main actor, so the pending payload is
    /// replaced by the newest bounded set of provider/signal observations.
    private func enqueueContextPressure(
        _ workspaceID: UUID,
        _ surfaceID: UUID,
        _ generation: UInt64,
        _ monitoringGeneration: UInt64,
        _ events: [AgentContextPressureEvent]
    ) {
        guard let contextPressureHandler else { return }
        let forward = TerminalContextPressureForward(
            generation: generation,
            monitoringGeneration: monitoringGeneration,
            events: events
        )
        guard forwardQueue.withLock({ state in
            state.contextPressureMonitoringEnabled
                && state.contextPressureMonitoringGeneration == monitoringGeneration
        }) else {
            return
        }
        let startDrain = forwardQueue.withLock { state in
            if let pending = state.contextPressurePending,
               pending.generation == forward.generation,
               pending.monitoringGeneration == forward.monitoringGeneration {
                state.contextPressurePending = TerminalContextPressureForward(
                    generation: forward.generation,
                    monitoringGeneration: monitoringGeneration,
                    events: Self.mergeContextPressureEvents(
                        pending.events,
                        forward.events
                    )
                )
            } else {
                state.contextPressurePending = TerminalContextPressureForward(
                    generation: forward.generation,
                    monitoringGeneration: monitoringGeneration,
                    events: forward.events
                )
            }
            guard !state.contextPressureDraining else { return false }
            state.contextPressureDraining = true
            return true
        }
        guard startDrain else { return }
        let forwardQueue = forwardQueue
        Task {
            while true {
                let next: TerminalContextPressureForward? = forwardQueue.withLock { state in
                    guard state.contextPressurePending != nil else {
                        state.contextPressureDraining = false
                        return nil
                    }
                    let next = state.contextPressurePending
                    state.contextPressurePending = nil
                    return next
                }
                guard let next else { return }
                await MainActor.run {
                    // Eligibility updates are MainActor-owned. Validate inside
                    // the same actor turn as the synchronous coordinator call
                    // so disable/rebind/re-enable cannot interleave at the hop.
                    let isCurrent = forwardQueue.withLock { state in
                        state.contextPressureMonitoringEnabled
                            && state.contextPressureMonitoringGeneration == next.monitoringGeneration
                    }
                    guard isCurrent else { return }
                    contextPressureHandler(
                        workspaceID,
                        surfaceID,
                        next.generation,
                        next.events
                    )
                }
            }
        }
    }

    private static func mergeContextPressureEvents(
        _ existing: [AgentContextPressureEvent],
        _ incoming: [AgentContextPressureEvent]
    ) -> [AgentContextPressureEvent] {
        var merged = existing
        for event in incoming {
            if let index = merged.firstIndex(where: {
                $0.provider == event.provider && $0.signal == event.signal
            }) {
                let previous = merged[index]
                merged[index] = AgentContextPressureEvent(
                    provider: event.provider,
                    signal: event.signal,
                    occurrence: max(previous.occurrence, event.occurrence)
                )
            } else {
                merged.append(event)
            }
        }
        return merged
    }
}
