import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation
import Observation

/// Owns restored-agent continuation, runtime replacement delivery, and completed process generations.
@MainActor
@Observable
final class RestoredAgentLifecycleCoordinator {
    /// Mixed-version events need only a short exact history; bounding it keeps
    /// repeatedly replaced sessions from becoming another retained runtime log.
    private static let supersededRuntimeBindingLimitPerPanel = 16
    /// Keep generation floors bounded even when many custom agent kinds are
    /// created and retired on one long-lived panel. Once the cap is reached,
    /// the overflow tombstone fails closed for unseen status keys rather than
    /// evicting a security floor and accepting an old runtime again.
    private static let runtimeGenerationHighWaterMarkLimitPerPanel = 32
    private static let runtimeGenerationFloorOverflowKey = "\u{001F}cmux-runtime-floor-overflow"

    @ObservationIgnored
    private let dateProvider: @MainActor () -> TimeInterval

    init(dateProvider: @escaping @MainActor () -> TimeInterval = { Date.now.timeIntervalSince1970 }) {
        self.dateProvider = dateProvider
    }

    var snapshotsByPanelId: [UUID: SessionRestorableAgentSnapshot] = [:] {
        didSet {
            completedGenerationsByPanelId = completedGenerationsByPanelId.filter { panelId, _ in
                snapshotsByPanelId[panelId] != nil
            }
        }
    }
    var resumeStatesByPanelId: [UUID: Workspace.RestoredAgentResumeState] = [:] {
        didSet {
            completedGenerationsByPanelId = completedGenerationsByPanelId.filter { panelId, _ in
                resumeStatesByPanelId[panelId] == .completedAgentExit
            }
            for (panelId, state) in resumeStatesByPanelId where state == .completedAgentExit {
                guard completedGenerationsByPanelId[panelId] == nil,
                      snapshotsByPanelId[panelId] != nil else {
                    continue
                }
                completedGenerationsByPanelId[panelId] = RestoredAgentCompletedGeneration(
                    completedAt: dateProvider(),
                    processIdentities: []
                )
            }
        }
    }
    var invalidatedFingerprintsByPanelId: [UUID: Int] = [:]

    private var completedGenerationsByPanelId: [UUID: RestoredAgentCompletedGeneration] = [:]
    private var supersededRuntimeBindingsByPanelId:
        [UUID: [SurfaceResumeBindingSnapshot]] = [:]
    private var retiredRuntimeBindingsByPanelId:
        [UUID: [SurfaceResumeBindingSnapshot]] = [:]
    private var pendingRuntimeReplacementBindingsByPanelId:
        [UUID: SurfaceResumeBindingSnapshot] = [:]
    private var currentRuntimeAuthoritiesByPanelId:
        [UUID: AgentRuntimeGenerationAuthority] = [:]
    private var retiredRuntimeAuthoritiesByPanelId:
        [UUID: [AgentRuntimeGenerationAuthority]] = [:]
    private var runtimeGenerationHighWaterMarksByPanelId:
        [UUID: [String: TimeInterval]] = [:]

    /// Returns the durable app-side generation floor for one panel and agent.
    /// The floor intentionally survives binding teardown so a reset hook store
    /// cannot restart the producer sequence below an already-retired runtime.
    func agentRuntimeGenerationFloor(
        statusKey: String,
        panelId: UUID
    ) -> TimeInterval? {
        guard statusKey != Self.runtimeGenerationFloorOverflowKey else { return nil }
        return runtimeGenerationHighWaterMarksByPanelId[panelId]?[statusKey]
    }

    /// Returns the persisted generation floors for one panel.
    func agentRuntimeGenerationFloors(panelId: UUID) -> [String: TimeInterval]? {
        runtimeGenerationHighWaterMarksByPanelId[panelId]
    }

    /// Restores app-owned generation floors before any binding or PID event can
    /// attempt to establish a runtime after an app restart.
    func seedAgentRuntimeGenerationFloors(
        _ floors: [String: TimeInterval]?,
        panelId: UUID
    ) {
        guard let floors, !floors.isEmpty else { return }
        for statusKey in floors.keys.sorted() {
            guard let generation = floors[statusKey], generation.isFinite, generation > 0 else {
                continue
            }
            if statusKey == Self.runtimeGenerationFloorOverflowKey {
                var current = runtimeGenerationHighWaterMarksByPanelId[panelId] ?? [:]
                current[statusKey] = max(current[statusKey] ?? 0, generation)
                runtimeGenerationHighWaterMarksByPanelId[panelId] = current
            } else {
                recordGenerationFloor(generation, statusKey: statusKey, panelId: panelId)
            }
        }
    }

    /// Whether an incoming binding can become the panel's runtime authority.
    /// Generated sessions must advance the high-water mark; generation-less
    /// legacy sessions may replace only other legacy sessions they have not
    /// already superseded.
    func canActivateAgentRuntimeBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard let sessionKey = binding.agentRuntimeSessionKey else { return true }
        return canEstablishAgentRuntime(
            sessionKey: sessionKey,
            generation: binding.runtimeGeneration,
            panelId: panelId
        )
    }

    /// Establishes authority from a binding or PID publication.
    @discardableResult
    func establishAgentRuntimeAuthority(
        sessionKey: AgentRuntimeSessionKey,
        generation: TimeInterval?,
        panelId: UUID
    ) -> Bool {
        guard canEstablishAgentRuntime(
            sessionKey: sessionKey,
            generation: generation,
            panelId: panelId
        ) else {
            return false
        }
        activateAgentRuntimeAuthority(
            sessionKey: sessionKey,
            generation: generation,
            panelId: panelId
        )
        return true
    }

    /// Authorizes an ordinary mutation against the already-established runtime.
    /// This read-only check deliberately cannot advance runtime authority.
    func allowsAgentRuntimeMutation(
        sessionKey: AgentRuntimeSessionKey,
        generation: TimeInterval?,
        panelId: UUID
    ) -> Bool {
        guard AgentRuntimeGenerationPolicy.isValid(generation),
              let current = currentRuntimeAuthoritiesByPanelId[panelId],
              runtimeSessionKeysMatch(current.sessionKey, sessionKey) else {
            return false
        }
        return AgentRuntimeGenerationPolicy.authorizesMutation(
            stored: current.generation,
            incoming: generation
        )
    }

    /// Authorizes a notification teardown after SessionEnd has retired its
    /// runtime. A retired runtime remains eligible only while the panel has no
    /// replacement authority, so delayed cleanup cannot erase the replacement's
    /// notification.
    func allowsAgentRuntimeNotificationCleanup(
        sessionKey: AgentRuntimeSessionKey,
        generation: TimeInterval?,
        panelId: UUID
    ) -> Bool {
        guard AgentRuntimeGenerationPolicy.isValid(generation) else { return false }
        if let current = currentRuntimeAuthoritiesByPanelId[panelId] {
            return runtimeSessionKeysMatch(current.sessionKey, sessionKey)
                && AgentRuntimeGenerationPolicy.authorizesMutation(
                    stored: current.generation,
                    incoming: generation
                )
        }
        return retiredRuntimeAuthoritiesByPanelId[panelId]?.contains { authority in
            runtimeSessionKeysMatch(authority.sessionKey, sessionKey)
                && AgentRuntimeGenerationPolicy.authorizesMutation(
                    stored: authority.generation,
                    incoming: generation
                )
        } == true
    }

    /// Consumes exact-session cleanup authority without depending on whether a
    /// prior alias is still present in the panel's PID-key collection.
    func consumeAgentRuntimeCleanupAuthority(
        sessionKey: AgentRuntimeSessionKey,
        generation: TimeInterval?,
        panelId: UUID
    ) -> Bool {
        guard AgentRuntimeGenerationPolicy.isValid(generation) else { return false }
        if let current = currentRuntimeAuthoritiesByPanelId[panelId],
           runtimeSessionKeysMatch(current.sessionKey, sessionKey) {
            guard AgentRuntimeGenerationPolicy.authorizesCleanup(
                stored: current.generation,
                incoming: generation
            ) else {
                return false
            }
            retireAgentRuntimeAuthority(current, panelId: panelId)
            currentRuntimeAuthoritiesByPanelId.removeValue(forKey: panelId)
            return true
        }
        return retiredRuntimeAuthoritiesByPanelId[panelId]?.contains { authority in
            runtimeSessionKeysMatch(authority.sessionKey, sessionKey)
                && AgentRuntimeGenerationPolicy.authorizesCleanup(
                    stored: authority.generation,
                    incoming: generation
                )
        } == true
    }

    /// Protects the current session's shared status/lifecycle slot while an
    /// older session alias is being removed.
    func protectsCurrentAgentRuntimeStatus(
        _ statusKey: String,
        clearingKey: String,
        panelId: UUID
    ) -> Bool {
        guard let current = currentRuntimeAuthoritiesByPanelId[panelId],
              current.sessionKey.statusKey == statusKey else {
            return false
        }
        return !current.sessionKey.compatibleRawValues.contains(clearingKey)
    }

    private func canEstablishAgentRuntime(
        sessionKey: AgentRuntimeSessionKey,
        generation: TimeInterval?,
        panelId: UUID
    ) -> Bool {
        guard AgentRuntimeGenerationPolicy.isValid(generation) else { return false }
        let highWaterMark = runtimeGenerationHighWaterMarksByPanelId[panelId]?[
            sessionKey.statusKey
        ]
        if let current = currentRuntimeAuthoritiesByPanelId[panelId],
           runtimeSessionKeysMatch(current.sessionKey, sessionKey) {
            switch (current.generation, generation) {
            case (nil, nil):
                return highWaterMark == nil
            case (nil, let incoming?):
                return incoming > (highWaterMark ?? 0)
            case (_?, nil):
                return false
            case (let stored?, let incoming?):
                return incoming >= stored
            }
        }

        if let generation {
            if highWaterMark == nil,
               runtimeGenerationHighWaterMarksByPanelId[panelId]?[Self.runtimeGenerationFloorOverflowKey] != nil {
                // The panel has reached its bounded floor capacity. Unknown
                // keys fail closed rather than allowing an evicted old runtime
                // to reclaim authority.
                return false
            }
            return generation > (highWaterMark ?? 0)
        }
        guard highWaterMark == nil else {
            return false
        }
        return retiredRuntimeAuthoritiesByPanelId[panelId]?.contains {
            runtimeSessionKeysMatch($0.sessionKey, sessionKey)
        } != true
    }

    /// Compares runtime keys using the same logical session identity rules as
    /// restored bindings (Pi/OMP UUIDs may arrive as either a UUID or a
    /// resolved `.jsonl` path). Raw key equality would reject that valid
    /// mixed-version representation during restore.
    private func runtimeSessionKeysMatch(
        _ lhs: AgentRuntimeSessionKey,
        _ rhs: AgentRuntimeSessionKey
    ) -> Bool {
        guard lhs.statusKey == rhs.statusKey else { return false }
        let kind: String
        if lhs.statusKey == "claude_code" {
            kind = "claude"
        } else {
            kind = lhs.statusKey
        }
        return ManagedAgentSessionIdentity.sessionIDsMatch(
            kind: kind,
            lhs: lhs.sessionID,
            rhs: rhs.sessionID
        )
    }

    private func recordGenerationFloor(
        _ generation: TimeInterval,
        statusKey: String,
        panelId: UUID
    ) {
        guard generation.isFinite, generation > 0 else { return }
        var marks = runtimeGenerationHighWaterMarksByPanelId[panelId] ?? [:]
        if statusKey == Self.runtimeGenerationFloorOverflowKey {
            marks[statusKey] = max(marks[statusKey] ?? 0, generation)
        } else if let existing = marks[statusKey] {
            marks[statusKey] = max(existing, generation)
        } else {
            let knownKeyCount = marks.keys.filter { $0 != Self.runtimeGenerationFloorOverflowKey }.count
            if knownKeyCount >= Self.runtimeGenerationHighWaterMarkLimitPerPanel {
                marks[Self.runtimeGenerationFloorOverflowKey] = max(
                    marks[Self.runtimeGenerationFloorOverflowKey] ?? 0,
                    generation
                )
            } else {
                marks[statusKey] = generation
            }
        }
        runtimeGenerationHighWaterMarksByPanelId[panelId] = marks
    }

    private func activateAgentRuntimeAuthority(
        sessionKey: AgentRuntimeSessionKey,
        generation: TimeInterval?,
        panelId: UUID
    ) {
        let current = currentRuntimeAuthoritiesByPanelId[panelId]
        if let current,
           !runtimeSessionKeysMatch(current.sessionKey, sessionKey) || (
               current.generation != nil
                && generation != nil
                && current.generation != generation
           ) {
            retireAgentRuntimeAuthority(current, panelId: panelId)
        }
        let effectiveGeneration: TimeInterval?
        if let current, runtimeSessionKeysMatch(current.sessionKey, sessionKey) {
            switch (current.generation, generation) {
            case let (stored?, incoming?):
                effectiveGeneration = max(stored, incoming)
            case let (stored?, nil):
                effectiveGeneration = stored
            case let (nil, incoming?):
                effectiveGeneration = incoming
            case (nil, nil):
                effectiveGeneration = nil
            }
        } else {
            effectiveGeneration = generation
        }
        currentRuntimeAuthoritiesByPanelId[panelId] = AgentRuntimeGenerationAuthority(
            sessionKey: sessionKey,
            generation: effectiveGeneration
        )
        if let effectiveGeneration {
            recordGenerationFloor(
                effectiveGeneration,
                statusKey: sessionKey.statusKey,
                panelId: panelId
            )
        }
    }

    private func retireAgentRuntimeAuthority(
        _ authority: AgentRuntimeGenerationAuthority,
        panelId: UUID
    ) {
        var retired = retiredRuntimeAuthoritiesByPanelId[panelId] ?? []
        retired.removeAll { $0 == authority }
        retired.append(authority)
        retiredRuntimeAuthoritiesByPanelId[panelId] = Array(
            retired.suffix(Self.supersededRuntimeBindingLimitPerPanel)
        )
    }

    private func retireAgentRuntimeAuthority(
        for binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) {
        guard let sessionKey = binding.agentRuntimeSessionKey else { return }
        let bindingAuthority = AgentRuntimeGenerationAuthority(
            sessionKey: sessionKey,
            generation: binding.runtimeGeneration
        )
        if let current = currentRuntimeAuthoritiesByPanelId[panelId],
           runtimeSessionKeysMatch(current.sessionKey, sessionKey),
           AgentRuntimeGenerationPolicy.authorizesCleanup(
               stored: current.generation,
               incoming: binding.runtimeGeneration
           ) {
            retireAgentRuntimeAuthority(current, panelId: panelId)
            currentRuntimeAuthoritiesByPanelId.removeValue(forKey: panelId)
        } else {
            retireAgentRuntimeAuthority(bindingAuthority, panelId: panelId)
        }
        if let generation = binding.runtimeGeneration {
            recordGenerationFloor(
                generation,
                statusKey: sessionKey.statusKey,
                panelId: panelId
            )
        }
    }

    /// Resolves the active or metadata-retired runtime authority displaced by
    /// `replacement`, records the transition, and returns the runtime to clear.
    func recordAgentRuntimeReplacementIfNeeded(
        currentBinding: SurfaceResumeBindingSnapshot?,
        replacement: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> SurfaceResumeBindingSnapshot? {
        guard let previous = currentBinding
                ?? eligibleRetiredAgentRuntimeBinding(panelId: panelId),
              previous.agentRuntimeStatusKey != nil,
              previous != replacement,
              !previous.isSameManagedAgentRuntime(as: replacement) else {
            return nil
        }
        recordAgentRuntimeReplacement(
            from: previous,
            to: replacement,
            panelId: panelId
        )
        return previous
    }

    /// Records the exact old binding rejected during a replacement and carries
    /// the notification-cleanup transition until the new session publishes PID ownership.
    private func recordAgentRuntimeReplacement(
        from previous: SurfaceResumeBindingSnapshot,
        to replacement: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) {
        var superseded = supersededRuntimeBindingsByPanelId[panelId] ?? []
        superseded.removeAll { binding in
            binding.isSameManagedAgentRuntime(as: replacement)
                || binding.isSameManagedAgentRuntime(as: previous)
        }
        superseded.append(previous)
        if superseded.count > Self.supersededRuntimeBindingLimitPerPanel {
            superseded.removeFirst(
                superseded.count - Self.supersededRuntimeBindingLimitPerPanel
            )
        }
        supersededRuntimeBindingsByPanelId[panelId] = superseded

        var retired = retiredRuntimeBindingsByPanelId[panelId] ?? []
        retired.removeAll { binding in
            binding.isSameManagedAgentRuntime(as: replacement)
                || binding.isSameManagedAgentRuntime(as: previous)
        }
        retired.append(previous)
        if retired.count > Self.supersededRuntimeBindingLimitPerPanel {
            retired.removeFirst(
                retired.count - Self.supersededRuntimeBindingLimitPerPanel
            )
        }
        retiredRuntimeBindingsByPanelId[panelId] = retired

        if replacement.agentRuntimeStatusKey != nil {
            pendingRuntimeReplacementBindingsByPanelId[panelId] = replacement
        } else {
            pendingRuntimeReplacementBindingsByPanelId.removeValue(forKey: panelId)
        }
    }

    /// Retains exact ownership after a binding clear so a following legacy PID
    /// clear can still resolve the dotted custom-agent status key safely. Only
    /// an authoritative session end also rejects a future PID publication; a
    /// metadata-only clear can be followed by a PID event for the live session.
    func recordAgentRuntimeRetirement(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID,
        agentSessionEnded: Bool
    ) {
        guard binding.agentRuntimeStatusKey != nil else { return }
        var retired = retiredRuntimeBindingsByPanelId[panelId] ?? []
        retired.removeAll { $0.isSameManagedAgentRuntime(as: binding) }
        retired.append(binding)
        retiredRuntimeBindingsByPanelId[panelId] = Array(
            retired.suffix(Self.supersededRuntimeBindingLimitPerPanel)
        )

        guard agentSessionEnded else { return }
        retireAgentRuntimeAuthority(for: binding, panelId: panelId)
        var superseded = supersededRuntimeBindingsByPanelId[panelId] ?? []
        superseded.removeAll { $0.isSameManagedAgentRuntime(as: binding) }
        superseded.append(binding)
        supersededRuntimeBindingsByPanelId[panelId] = Array(
            superseded.suffix(Self.supersededRuntimeBindingLimitPerPanel)
        )
        if pendingRuntimeReplacementBindingsByPanelId[panelId]?
            .isSameManagedAgentRuntime(as: binding) == true {
            pendingRuntimeReplacementBindingsByPanelId.removeValue(forKey: panelId)
        }
    }

    /// Whether a legacy runtime key exactly matches a recently superseded binding.
    func rejectsSupersededAgentRuntimeKey(_ key: String, panelId: UUID) -> Bool {
        if currentRuntimeAuthoritiesByPanelId[panelId]?.sessionKey.compatibleRawValues
            .contains(key) == true {
            return false
        }
        return supersededRuntimeBindingsByPanelId[panelId]?.contains {
            $0.matchesExactAgentRuntimeKey(key)
        } == true || retiredRuntimeAuthoritiesByPanelId[panelId]?.contains {
            $0.sessionKey.compatibleRawValues.contains(key)
        } == true
    }

    /// Resolves a retired exact key without reparsing a dotted agent identifier.
    func retiredAgentRuntimeStatusKey(
        for key: String,
        panelId: UUID
    ) -> String? {
        retiredRuntimeBinding(for: key, panelId: panelId)?
            .agentRuntimeStatusKey
            ?? retiredRuntimeAuthoritiesByPanelId[panelId]?.last(where: {
                $0.sessionKey.compatibleRawValues.contains(key)
            })?.sessionKey.statusKey
    }

    /// Returns the newest non-superseded retirement that can still publish runtime events.
    func eligibleRetiredAgentRuntimeBinding(
        panelId: UUID
    ) -> SurfaceResumeBindingSnapshot? {
        let superseded = supersededRuntimeBindingsByPanelId[panelId] ?? []
        return retiredRuntimeBindingsByPanelId[panelId]?.last { candidate in
            !superseded.contains {
                $0.isSameManagedAgentRuntime(as: candidate)
            }
        }
    }

    /// Resolves a retired binding for an exact control-plane teardown request.
    func retiredAgentRuntimeBinding(
        panelId: UUID,
        checkpointID: String?,
        source: String?,
        runtimeStatusKey: String? = nil,
        runtimeGeneration: TimeInterval? = nil
    ) -> SurfaceResumeBindingSnapshot? {
        guard runtimeGeneration == nil || runtimeStatusKey != nil else {
            return nil
        }
        retiredRuntimeBindingsByPanelId[panelId]?.last { binding in
            (checkpointID == nil || binding.checkpointId == checkpointID)
                && (source == nil || binding.source == source)
                && (runtimeStatusKey == nil
                    || binding.agentRuntimeStatusKey == runtimeStatusKey)
                && AgentRuntimeGenerationPolicy.authorizesCleanup(
                    stored: binding.runtimeGeneration,
                    incoming: runtimeGeneration
                )
        }
    }

    /// Promotes an already-retired binding when its authoritative session end arrives.
    @discardableResult
    func endRetiredAgentRuntimeBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard retiredRuntimeBindingsByPanelId[panelId]?.contains(where: {
            $0.isSameManagedAgentRuntime(as: binding)
        }) == true else {
            return false
        }
        recordAgentRuntimeRetirement(
            binding,
            panelId: panelId,
            agentSessionEnded: true
        )
        return true
    }

    private func retiredRuntimeBinding(
        for key: String,
        panelId: UUID
    ) -> SurfaceResumeBindingSnapshot? {
        retiredRuntimeBindingsByPanelId[panelId]?
            .last(where: { $0.matchesExactAgentRuntimeKey(key) })
    }

    /// Promotes older retirements to superseded while allowing intentional reuse.
    func activateAgentRuntimeBinding(
        _ binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) {
        if let sessionKey = binding.agentRuntimeSessionKey {
            activateAgentRuntimeAuthority(
                sessionKey: sessionKey,
                generation: binding.runtimeGeneration,
                panelId: panelId
            )
        } else if let current = currentRuntimeAuthoritiesByPanelId.removeValue(forKey: panelId) {
            retireAgentRuntimeAuthority(current, panelId: panelId)
        }
        let retired = retiredRuntimeBindingsByPanelId[panelId] ?? []
        var superseded = supersededRuntimeBindingsByPanelId[panelId] ?? []
        for retiredBinding in retired
        where !retiredBinding.isSameManagedAgentRuntime(as: binding) {
            superseded.removeAll {
                $0.isSameManagedAgentRuntime(as: retiredBinding)
            }
            superseded.append(retiredBinding)
        }
        superseded.removeAll { $0.isSameManagedAgentRuntime(as: binding) }
        let boundedSuperseded = Array(
            superseded.suffix(Self.supersededRuntimeBindingLimitPerPanel)
        )
        if boundedSuperseded.isEmpty {
            supersededRuntimeBindingsByPanelId.removeValue(forKey: panelId)
        } else {
            supersededRuntimeBindingsByPanelId[panelId] = boundedSuperseded
        }

        let remainingRetired = retired.filter {
            !$0.isSameManagedAgentRuntime(as: binding)
        }
        if remainingRetired.isEmpty {
            retiredRuntimeBindingsByPanelId.removeValue(forKey: panelId)
        } else {
            retiredRuntimeBindingsByPanelId[panelId] = remainingRetired
        }
    }

    /// Consumes the replacement transition reported by the next authoritative PID event.
    func consumePendingAgentRuntimeReplacement(
        for binding: SurfaceResumeBindingSnapshot,
        panelId: UUID
    ) -> Bool {
        guard pendingRuntimeReplacementBindingsByPanelId[panelId]?
            .isSameManagedAgentRuntime(as: binding) == true else {
            return false
        }
        pendingRuntimeReplacementBindingsByPanelId.removeValue(forKey: panelId)
        return true
    }

    /// Drops replacement delivery state when its panel is permanently discarded.
    func clearAgentRuntimeReplacementTracking(panelId: UUID) {
        supersededRuntimeBindingsByPanelId.removeValue(forKey: panelId)
        retiredRuntimeBindingsByPanelId.removeValue(forKey: panelId)
        pendingRuntimeReplacementBindingsByPanelId.removeValue(forKey: panelId)
        currentRuntimeAuthoritiesByPanelId.removeValue(forKey: panelId)
        retiredRuntimeAuthoritiesByPanelId.removeValue(forKey: panelId)
        runtimeGenerationHighWaterMarksByPanelId.removeValue(forKey: panelId)
    }

    /// Drops all replacement delivery state during a full owner reset.
    func clearAllAgentRuntimeReplacementTracking() {
        supersededRuntimeBindingsByPanelId.removeAll(keepingCapacity: false)
        retiredRuntimeBindingsByPanelId.removeAll(keepingCapacity: false)
        pendingRuntimeReplacementBindingsByPanelId.removeAll(keepingCapacity: false)
        currentRuntimeAuthoritiesByPanelId.removeAll(keepingCapacity: false)
        retiredRuntimeAuthoritiesByPanelId.removeAll(keepingCapacity: false)
        runtimeGenerationHighWaterMarksByPanelId.removeAll(keepingCapacity: false)
    }

    /// Prunes replacement delivery state alongside the owner's live panel set.
    func retainAgentRuntimeReplacementTracking(panelIds: Set<UUID>) {
        supersededRuntimeBindingsByPanelId = supersededRuntimeBindingsByPanelId.filter {
            panelIds.contains($0.key)
        }
        retiredRuntimeBindingsByPanelId = retiredRuntimeBindingsByPanelId.filter {
            panelIds.contains($0.key)
        }
        pendingRuntimeReplacementBindingsByPanelId =
            pendingRuntimeReplacementBindingsByPanelId.filter {
                panelIds.contains($0.key)
            }
        currentRuntimeAuthoritiesByPanelId = currentRuntimeAuthoritiesByPanelId.filter {
            panelIds.contains($0.key)
        }
        retiredRuntimeAuthoritiesByPanelId = retiredRuntimeAuthoritiesByPanelId.filter {
            panelIds.contains($0.key)
        }
        runtimeGenerationHighWaterMarksByPanelId =
            runtimeGenerationHighWaterMarksByPanelId.filter {
                panelIds.contains($0.key)
            }
    }

    /// Captures transient delivery guards for a live panel transfer.
    func agentRuntimeReplacementTrackingState(
        panelId: UUID
    ) -> AgentRuntimeReplacementTrackingState? {
        let superseded = supersededRuntimeBindingsByPanelId[panelId] ?? []
        let retired = retiredRuntimeBindingsByPanelId[panelId] ?? []
        let pendingReplacement = pendingRuntimeReplacementBindingsByPanelId[panelId]
        let currentAuthority = currentRuntimeAuthoritiesByPanelId[panelId]
        let retiredAuthorities = retiredRuntimeAuthoritiesByPanelId[panelId] ?? []
        let generationHighWaterMarks = runtimeGenerationHighWaterMarksByPanelId[panelId] ?? [:]
        guard !superseded.isEmpty || !retired.isEmpty || pendingReplacement != nil
                || currentAuthority != nil || !retiredAuthorities.isEmpty
                || !generationHighWaterMarks.isEmpty else {
            return nil
        }
        return AgentRuntimeReplacementTrackingState(
            supersededBindings: superseded,
            retiredBindings: retired,
            pendingReplacementBinding: pendingReplacement,
            currentAuthority: currentAuthority,
            retiredAuthorities: retiredAuthorities,
            generationHighWaterMarksByStatusKey: generationHighWaterMarks
        )
    }

    /// Adopts transient delivery guards after a live panel transfer.
    func seedAgentRuntimeReplacementTracking(
        _ state: AgentRuntimeReplacementTrackingState?,
        panelId: UUID
    ) {
        clearAgentRuntimeReplacementTracking(panelId: panelId)
        guard let state else { return }
        supersededRuntimeBindingsByPanelId[panelId] = Array(
            state.supersededBindings.suffix(
                Self.supersededRuntimeBindingLimitPerPanel
            )
        )
        retiredRuntimeBindingsByPanelId[panelId] = Array(
            state.retiredBindings.suffix(
                Self.supersededRuntimeBindingLimitPerPanel
            )
        )
        if let pendingReplacement = state.pendingReplacementBinding {
            pendingRuntimeReplacementBindingsByPanelId[panelId] = pendingReplacement
        }
        if let currentAuthority = state.currentAuthority {
            currentRuntimeAuthoritiesByPanelId[panelId] = currentAuthority
        }
        retiredRuntimeAuthoritiesByPanelId[panelId] = Array(
            state.retiredAuthorities.suffix(
                Self.supersededRuntimeBindingLimitPerPanel
            )
        )
        if !state.generationHighWaterMarksByStatusKey.isEmpty {
            runtimeGenerationHighWaterMarksByPanelId[panelId] =
                state.generationHighWaterMarksByStatusKey
        }
    }

    func markCompleted(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry?,
        runtimeProcessIdentities: Set<AgentPIDProcessIdentity>
    ) {
        let observedProcessIdentities = Set(
            observation.map { Array($0.agentProcessIdentities.values) } ?? []
        )
        completedGenerationsByPanelId[panelId] = RestoredAgentCompletedGeneration(
            completedAt: dateProvider(),
            processIdentities: runtimeProcessIdentities.union(observedProcessIdentities)
        )
        resumeStatesByPanelId[panelId] = .completedAgentExit
    }

    func continuationSnapshot(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry?,
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> SessionRestorableAgentSnapshot? {
        guard resumeStatesByPanelId[panelId] == .completedAgentExit else {
            return snapshotsByPanelId[panelId]
        }
        guard let observation,
              observationSupersedesCompletion(
                  panelId: panelId,
                  observation: observation,
                  currentProcessIdentity: currentProcessIdentity
              ) else {
            return nil
        }
        return observation.snapshot
    }

    @discardableResult
    func reconcileCompletedAgent(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry,
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> Bool {
        guard resumeStatesByPanelId[panelId] == .completedAgentExit,
              observationSupersedesCompletion(
                  panelId: panelId,
                  observation: observation,
                  currentProcessIdentity: currentProcessIdentity
              ) else {
            return false
        }
        snapshotsByPanelId[panelId] = observation.snapshot
        resumeStatesByPanelId[panelId] = .observedAgentCommandRunning
        invalidatedFingerprintsByPanelId.removeValue(forKey: panelId)
        completedGenerationsByPanelId.removeValue(forKey: panelId)
        return true
    }

    func completedGeneration(panelId: UUID) -> RestoredAgentCompletedGeneration? {
        completedGenerationsByPanelId[panelId]
    }

    /// Shell integration has observed the restored launch enter its command
    /// phase and has not subsequently reported the prompt returning.
    func confirmsRunningRestoredCommand(panelId: UUID) -> Bool {
        switch resumeStatesByPanelId[panelId] {
        case .autoResumeCommandRunning, .observedAgentCommandRunning:
            true
        case .manualResumeAvailable, .awaitingAutoResumeCommand, .completedAgentExit, nil:
            false
        }
    }

    /// The restored launch still owns its binding while startup input is
    /// queued, even though only a later shell callback can prove it is running.
    func ownsInFlightRestoredCommand(panelId: UUID) -> Bool {
        switch resumeStatesByPanelId[panelId] {
        case .awaitingAutoResumeCommand, .autoResumeCommandRunning, .observedAgentCommandRunning:
            true
        case .manualResumeAvailable, .completedAgentExit, nil:
            false
        }
    }

    func seedTransferredState(
        panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot?,
        resumeState: Workspace.RestoredAgentResumeState?,
        completedGeneration: RestoredAgentCompletedGeneration?
    ) {
        if let snapshot {
            snapshotsByPanelId[panelId] = snapshot
        } else {
            snapshotsByPanelId.removeValue(forKey: panelId)
        }

        if resumeState == .completedAgentExit, let completedGeneration {
            completedGenerationsByPanelId[panelId] = completedGeneration
        } else {
            completedGenerationsByPanelId.removeValue(forKey: panelId)
        }

        if let resumeState {
            resumeStatesByPanelId[panelId] = resumeState
        } else {
            resumeStatesByPanelId.removeValue(forKey: panelId)
        }
    }

    private func observationSupersedesCompletion(
        panelId: UUID,
        observation: RestorableAgentSessionIndex.Entry,
        currentProcessIdentity: (pid_t) -> AgentPIDProcessIdentity?
    ) -> Bool {
        guard let completed = completedGenerationsByPanelId[panelId] else {
            return false
        }

        let observedIdentities = Set(observation.agentProcessIdentities.values)
        let currentCandidateIdentities = Set(observedIdentities.filter { identity in
            currentProcessIdentity(identity.pid) == identity
        })
        if !observedIdentities.isEmpty {
            let newerIdentities = currentCandidateIdentities.subtracting(completed.processIdentities)
            return newerIdentities.contains { identity in
                let startedAt = TimeInterval(identity.startSeconds) +
                    TimeInterval(identity.startMicroseconds) / 1_000_000
                return startedAt > completed.completedAt
            }
        }
        return false
    }
}
