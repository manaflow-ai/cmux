import CMUXAgentLaunch
import CmuxAgentChat
import CmuxSidebar
import Foundation

/// Keeps the opt-in sidebar agent usage (`sidebar.showAgentUsage`) current.
///
/// Agent hook events (Claude Code, Codex) mark a session's transcript as
/// dirty. After a short coalescing delay the transcript is sampled by the
/// ``AgentUsageSampler`` actor, which reads only newly appended bytes off the
/// main actor, and the resulting Sendable snapshot is stored on the
/// workspace's ``WorkspaceSidebarMetadataModel`` under the agent's status key.
///
/// Nothing is read while the setting is off (or "Hide All Details" is on):
/// events are dropped, pending samples are cancelled, and previously shown
/// usage is cleared. There is no polling; usage refreshes only when the agent
/// reports a hook event.
@MainActor
final class SidebarAgentUsageCoordinator {
    typealias MetadataLookup = @MainActor (UUID) -> WorkspaceSidebarMetadataModel?

    private struct PendingSample {
        let transcriptPath: String
        let source: AgentUsageSource
        let workspaceID: UUID
    }

    private let sampler: AgentUsageSampler
    private let defaults: UserDefaults
    private let coalesceInterval: Duration
    private let clock: any Clock<Duration>
    private let metadataLookup: MetadataLookup
    private var pendingBySessionID: [String: PendingSample] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    private var workspaceIDsShowingUsage: Set<UUID> = []
    private var observationTask: Task<Void, Never>?

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - sampler: Off-main transcript sampler.
    ///   - defaults: Settings store for `sidebar.showAgentUsage` and
    ///     `sidebar.hideAllDetails`.
    ///   - coalesceInterval: Delay that folds a burst of hook events (tool
    ///     storms) into one transcript read per session.
    ///   - clock: Clock driving the coalescing delay (tests inject their own).
    ///   - metadataLookup: Resolves a workspace id to its sidebar metadata.
    init(
        sampler: AgentUsageSampler = AgentUsageSampler(),
        defaults: UserDefaults = .standard,
        coalesceInterval: Duration = .milliseconds(750),
        clock: any Clock<Duration> = ContinuousClock(),
        metadataLookup: @escaping MetadataLookup
    ) {
        self.sampler = sampler
        self.defaults = defaults
        self.coalesceInterval = coalesceInterval
        self.clock = clock
        self.metadataLookup = metadataLookup
    }

    /// Starts consuming accepted agent hook events for the app's lifetime.
    ///
    /// The observation task holds the coordinator, so the composition root
    /// can start it without storing it. Idempotent.
    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { @MainActor in
            for await notification in NotificationCenter.default.notifications(named: .workstreamEventReceived) {
                guard !Task.isCancelled else { return }
                guard let event = notification.object as? WorkstreamEvent else { continue }
                self.noteHookEvent(event)
            }
        }
    }

    /// Whether usage is currently displayed (and therefore sampled).
    var isEnabled: Bool {
        SidebarWorkspaceDetailDefaults.auxiliaryDetailVisibility(defaults: defaults).showsAgentUsage
    }

    /// Records one accepted hook event and schedules a coalesced sample of
    /// its session transcript.
    ///
    /// - Parameter event: The hook event as accepted by the feed pipeline.
    func noteHookEvent(_ event: WorkstreamEvent) {
        guard let source = AgentUsageSource(hookSource: event.source),
              let workspaceID = event.workspaceId.flatMap(UUID.init(uuidString:)) else { return }
        guard isEnabled else {
            clearAll()
            return
        }
        switch event.hookEventName {
        case .sessionStart, .sessionEnd:
            // A new or finished session must not keep the previous one's numbers.
            metadataLookup(workspaceID)?.updateAgentUsage(nil, forStatusKey: source.sidebarStatusKey)
            if event.hookEventName == .sessionEnd {
                cancelPending(sessionID: event.sessionId)
                if let path = event.transcriptPath {
                    Task { [sampler] in await sampler.forget(transcriptPath: path) }
                }
                return
            }
        default:
            break
        }
        guard let transcriptPath = event.transcriptPath, !transcriptPath.isEmpty else { return }
        pendingBySessionID[event.sessionId] = PendingSample(
            transcriptPath: transcriptPath,
            source: source,
            workspaceID: workspaceID
        )
        scheduleFlush(sessionID: event.sessionId)
    }

    private func scheduleFlush(sessionID: String) {
        guard flushTasks[sessionID] == nil else { return }
        flushTasks[sessionID] = Task { @MainActor [weak self, clock, coalesceInterval] in
            do {
                // Bounded, cancellable coalescing delay (not a poll).
                try await clock.sleep(for: coalesceInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flush(sessionID: sessionID)
        }
    }

    private func flush(sessionID: String) async {
        defer {
            // A cancelled flush was already removed by whoever cancelled it.
            if !Task.isCancelled {
                flushTasks[sessionID] = nil
                // Events that arrived while sampling get their own pass.
                if pendingBySessionID[sessionID] != nil { scheduleFlush(sessionID: sessionID) }
            }
        }
        guard let pending = pendingBySessionID.removeValue(forKey: sessionID), isEnabled else { return }
        let snapshot = await sampler.sample(transcriptPath: pending.transcriptPath, source: pending.source)
        // The setting may have flipped, or the session ended, while sampling.
        guard isEnabled, !Task.isCancelled,
              let metadata = metadataLookup(pending.workspaceID) else { return }
        metadata.updateAgentUsage(snapshot.map(Self.sidebarUsage), forStatusKey: pending.source.sidebarStatusKey)
        if snapshot != nil {
            workspaceIDsShowingUsage.insert(pending.workspaceID)
        }
    }

    private func cancelPending(sessionID: String) {
        flushTasks.removeValue(forKey: sessionID)?.cancel()
        pendingBySessionID[sessionID] = nil
    }

    private func clearAll() {
        for task in flushTasks.values { task.cancel() }
        flushTasks.removeAll()
        pendingBySessionID.removeAll()
        guard !workspaceIDsShowingUsage.isEmpty else { return }
        for workspaceID in workspaceIDsShowingUsage {
            guard let metadata = metadataLookup(workspaceID) else { continue }
            for source in AgentUsageSource.allCases {
                metadata.updateAgentUsage(nil, forStatusKey: source.sidebarStatusKey)
            }
        }
        workspaceIDsShowingUsage.removeAll()
        Task { [sampler] in await sampler.reset() }
    }

    static func sidebarUsage(_ snapshot: AgentUsageSnapshot) -> SidebarAgentUsage {
        SidebarAgentUsage(
            modelName: snapshot.modelDisplayName,
            contextFraction: snapshot.contextFraction,
            estimatedCostUSD: snapshot.estimatedCostUSD
        )
    }
}
