import CMUXAgentLaunch
import CmuxAgentChat
import CmuxSidebar
import Foundation

/// Keeps the opt-in sidebar agent usage (`sidebar.showAgentUsage`) current.
///
/// Every accepted Claude Code / Codex hook event updates a lightweight
/// per-session record (workspace, transcript path, last activity); no I/O.
/// While the setting is on, the event also schedules a coalesced sample of
/// that session's transcript through the ``AgentUsageSampler`` actor, which
/// reads only new bytes off the main actor.
///
/// **Which session a row shows.** A workspace has one status entry per agent
/// (`claude_code`, `codex`), written by whichever session reported last. The
/// usage appended to it is therefore the usage of the most recently active
/// session of that agent in the workspace, so the numbers always describe
/// the session the status text describes. Other sessions keep their own
/// records: a `SessionStart`/`SessionEnd` in one pane never erases another
/// pane's usage, and the row switches back when that pane reports again.
///
/// **Setting changes** are observed directly: turning the setting (or its
/// prerequisites, "Hide All Details" off and metadata shown) on samples every
/// known session immediately; turning it off cancels pending samples,
/// clears shown usage, and drops the sampler's cursors. There is no polling.
@MainActor
final class SidebarAgentUsageCoordinator {
    typealias MetadataLookup = @MainActor (UUID) -> WorkspaceSidebarMetadataModel?

    private struct SessionRecord {
        let source: AgentUsageSource
        var workspaceID: UUID
        var transcriptPath: String?
        var lastEventAt: Date
        /// Bumped on `SessionStart`, so a sample started for the previous
        /// run of a resumed session id is discarded.
        var epoch: UInt64
        var snapshot: AgentUsageSnapshot?
    }

    private struct RowKey: Hashable {
        let workspaceID: UUID
        let source: AgentUsageSource
    }

    /// Records kept for idle sessions; the least recently active is dropped.
    static let maxTrackedSessions = 64

    private let sampler: AgentUsageSampler
    private let defaults: UserDefaults
    private let coalesceInterval: Duration
    private let clock: any Clock<Duration>
    private let metadataLookup: MetadataLookup
    private var sessions: [String: SessionRecord] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    private var dirtyWhileReading: Set<String> = []
    private var readingSessionIDs: Set<String> = []
    private var rowsShowingUsage: Set<RowKey> = []
    private var epochCounter: UInt64 = 0
    private var lastKnownEnabled: Bool
    private var observationTasks: [Task<Void, Never>] = []

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - sampler: Off-main transcript sampler.
    ///   - defaults: Settings store for `sidebar.showAgentUsage`,
    ///     `sidebar.showCustomMetadata` and `sidebar.hideAllDetails`.
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
        lastKnownEnabled = Self.isEnabled(defaults: defaults)
    }

    /// Starts consuming accepted agent hook events and settings changes for
    /// the app's lifetime. The observation tasks hold the coordinator, so
    /// the composition root can start it without storing it. Idempotent.
    func start() {
        guard observationTasks.isEmpty else { return }
        observationTasks.append(Task { @MainActor in
            for await notification in NotificationCenter.default.notifications(named: .workstreamEventReceived) {
                guard !Task.isCancelled else { return }
                guard let event = notification.object as? WorkstreamEvent else { continue }
                self.noteHookEvent(event)
            }
        })
        observationTasks.append(Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                guard !Task.isCancelled else { return }
                self.settingsDidChange()
            }
        })
    }

    /// Whether usage is displayed, and therefore sampled.
    var isEnabled: Bool {
        Self.isEnabled(defaults: defaults)
    }

    private static func isEnabled(defaults: UserDefaults) -> Bool {
        let visibility = SidebarWorkspaceDetailDefaults.auxiliaryDetailVisibility(defaults: defaults)
        // Usage renders inside the metadata rows; no rows, no reads.
        return visibility.showsAgentUsage && visibility.showsMetadata
    }

    /// Reacts to a settings change: samples every known session when usage
    /// becomes visible, clears everything when it stops being visible.
    func settingsDidChange() {
        let enabled = isEnabled
        guard enabled != lastKnownEnabled else { return }
        lastKnownEnabled = enabled
        if enabled {
            for sessionID in sessions.keys { scheduleFlush(sessionID: sessionID) }
        } else {
            clearAll()
        }
    }

    /// Records one accepted hook event and, while enabled, schedules a
    /// coalesced sample of its session transcript.
    ///
    /// - Parameter event: The hook event as accepted by the feed pipeline.
    func noteHookEvent(_ event: WorkstreamEvent) {
        guard let source = AgentUsageSource(hookSource: event.source),
              let workspaceID = event.workspaceId.flatMap(UUID.init(uuidString:)) else { return }
        let sessionID = event.sessionId
        if event.hookEventName == .sessionEnd {
            endSession(sessionID)
            return
        }
        var record = sessions[sessionID] ?? SessionRecord(
            source: source,
            workspaceID: workspaceID,
            transcriptPath: nil,
            lastEventAt: event.receivedAt,
            epoch: 0,
            snapshot: nil
        )
        if event.hookEventName == .sessionStart || sessions[sessionID] == nil {
            // A new or resumed run must not show the previous run's numbers.
            epochCounter &+= 1
            record.epoch = epochCounter
            record.snapshot = nil
        }
        let previousWorkspaceID = record.workspaceID
        record.workspaceID = workspaceID
        record.lastEventAt = max(record.lastEventAt, event.receivedAt)
        if let path = event.transcriptPath, !path.isEmpty {
            record.transcriptPath = path
        }
        sessions[sessionID] = record
        evictIfNeeded()
        publish(RowKey(workspaceID: workspaceID, source: source))
        if previousWorkspaceID != workspaceID {
            publish(RowKey(workspaceID: previousWorkspaceID, source: source))
        }
        if isEnabled, record.transcriptPath != nil {
            scheduleFlush(sessionID: sessionID)
        }
    }

    private func endSession(_ sessionID: String) {
        flushTasks.removeValue(forKey: sessionID)?.cancel()
        dirtyWhileReading.remove(sessionID)
        readingSessionIDs.remove(sessionID)
        guard let record = sessions.removeValue(forKey: sessionID) else { return }
        if let path = record.transcriptPath {
            // Also discards a sample of this transcript that is still running.
            Task { [sampler] in await sampler.forget(transcriptPath: path) }
        }
        publish(RowKey(workspaceID: record.workspaceID, source: record.source))
    }

    private func scheduleFlush(sessionID: String) {
        guard flushTasks[sessionID] == nil else {
            if readingSessionIDs.contains(sessionID) { dirtyWhileReading.insert(sessionID) }
            return
        }
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
                readingSessionIDs.remove(sessionID)
                // Events that arrived while reading get their own pass.
                if dirtyWhileReading.remove(sessionID) != nil { scheduleFlush(sessionID: sessionID) }
            }
        }
        guard isEnabled, let record = sessions[sessionID], let path = record.transcriptPath else { return }
        readingSessionIDs.insert(sessionID)
        let snapshot = await sampler.sample(transcriptPath: path, source: record.source)
        // The setting may have flipped, or the session ended or restarted,
        // while sampling; `nil` means "nothing new" and keeps what is shown.
        guard !Task.isCancelled, isEnabled, let snapshot,
              var current = sessions[sessionID],
              current.epoch == record.epoch,
              current.transcriptPath == path else { return }
        current.snapshot = snapshot
        sessions[sessionID] = current
        publish(RowKey(workspaceID: current.workspaceID, source: current.source))
    }

    /// Shows the usage of the most recently active session of `row.source`
    /// in `row.workspaceID` (see the type documentation).
    private func publish(_ row: RowKey) {
        let owner = sessions.values
            .filter { $0.workspaceID == row.workspaceID && $0.source == row.source }
            .max { $0.lastEventAt < $1.lastEventAt }
        let usage = isEnabled ? owner?.snapshot.map(Self.sidebarUsage) : nil
        if usage == nil, !rowsShowingUsage.contains(row) { return }
        metadataLookup(row.workspaceID)?.updateAgentUsage(usage, forStatusKey: row.source.sidebarStatusKey)
        if usage == nil {
            rowsShowingUsage.remove(row)
        } else {
            rowsShowingUsage.insert(row)
        }
    }

    private func evictIfNeeded() {
        while sessions.count > Self.maxTrackedSessions,
              let oldest = sessions.min(by: { $0.value.lastEventAt < $1.value.lastEventAt })?.key {
            endSession(oldest)
        }
    }

    private func clearAll() {
        for task in flushTasks.values { task.cancel() }
        flushTasks.removeAll()
        dirtyWhileReading.removeAll()
        readingSessionIDs.removeAll()
        for sessionID in Array(sessions.keys) {
            sessions[sessionID]?.snapshot = nil
        }
        for row in rowsShowingUsage {
            metadataLookup(row.workspaceID)?.updateAgentUsage(nil, forStatusKey: row.source.sidebarStatusKey)
        }
        rowsShowingUsage.removeAll()
        Task { [sampler] in await sampler.reset() }
    }

    /// Waits until no sample is scheduled or running (tests use this to
    /// observe the result of a coalesced sample deterministically).
    func waitUntilIdle() async {
        while let task = flushTasks.values.first {
            await task.value
        }
    }

    static func sidebarUsage(_ snapshot: AgentUsageSnapshot) -> SidebarAgentUsage {
        SidebarAgentUsage(
            modelName: snapshot.modelDisplayName,
            contextFraction: snapshot.contextFraction,
            estimatedCostUSD: snapshot.estimatedCost?.usd,
            costIsLowerBound: snapshot.estimatedCost?.isLowerBound ?? false
        )
    }
}
