import CmuxAgentJournal
import Foundation

extension AgentJournalLifecycleCenter {
    // MARK: - Consumer

    struct LifecycleApplication: Sendable {
        let assignment: AgentLifecycleAssignment
        let workspaceHint: String?
    }

    static func reduceIngest(
        _ event: AgentJournalEvent,
        aliases: AgentJournalAliasResolver,
        reducer: AgentLifecycleReducer,
        state: inout AgentLifecycleReducerState
    ) -> LifecycleApplication? {
        guard event.kind != .messagePublished else { return nil }
        let canonical = canonicalized(event, aliases: aliases)
        reducer.apply(canonical, to: &state)
        guard canonical.draft.unattributedReason == nil else {
            publishUnattributedDiagnostic(canonical)
            return nil
        }
        guard let surfaceId = canonical.draft.surfaceId else {
            publishUnattributedDiagnostic(canonical)
            return nil
        }
        guard !canonical.draft.isSubagent else { return nil }
        return LifecycleApplication(
            assignment: AgentLifecycleAssignment(
                surfaceId: surfaceId,
                agentKey: canonical.agentKey,
                phase: state.combinedPhase(surfaceId: surfaceId, agentKey: canonical.agentKey)
            ),
            workspaceHint: canonical.draft.workspaceId
        )
    }

    static func reduceStartupReplay(
        store: AgentJournalStore,
        aliases: AgentJournalAliasResolver,
        reducer: AgentLifecycleReducer,
        replayPolicy: AgentJournalReplayPolicy,
        state: inout AgentLifecycleReducerState,
        notifications: inout AgentNotificationReconciler
    ) -> [AgentLifecycleAssignment] {
        var cursor: Int64 = 0
        var folded = 0
        var skipped = 0
        while true {
            let page: AgentJournalReadPage
            do {
                page = try store.readPage(afterSequence: cursor, limit: 2_048)
            } catch {
                // An incomplete fold must not paint partial replay state:
                // record the failure and paint nothing (live events still
                // reduce and self-correct per session).
                CmuxEventBus.shared.publish(
                    name: "agent.journal.replay_failed",
                    category: "agent",
                    source: "journal",
                    payload: ["cursor": cursor, "folded": folded]
                )
#if DEBUG
                cmuxDebugLog("agentJournal.replay.error cursor=\(cursor) \(String(describing: error))")
#endif
                return []
            }
            if page.isEmpty { break }
            for event in page.events {
                let canonical = canonicalized(event, aliases: aliases)
                let decision = notifications.apply(canonical)
                if decision.disposition != .stale, decision.projectsLifecycle {
                    reducer.apply(notifications.lifecycleEvent(canonical), to: &state)
                }
            }
            folded += page.events.count
            skipped += page.skippedSequences.count
            // Advance over undecodable rows too so a foreign-schema run can
            // never stall the fold or hide the events behind it.
            cursor = page.scannedThroughSequence
        }
        let startup = replayPolicy.startupSnapshot(from: state.snapshot())
        var assignments: [AgentLifecycleAssignment] = []
        for (surfaceId, byAgent) in startup.phases {
            for (agentKey, phase) in byAgent {
                assignments.append(
                    AgentLifecycleAssignment(surfaceId: surfaceId, agentKey: agentKey, phase: phase)
                )
            }
        }
#if DEBUG
        cmuxDebugLog(
            "agentJournal.replay folded=\(folded) skipped=\(skipped) " +
                "painted=\(assignments.count) unattributed=\(state.unattributedEvents.count)"
        )
#endif
        return assignments
    }

    /// Rewrites the event's identity through the restore alias chains so
    /// sessions that span an app relaunch reduce under one canonical surface.
    static func canonicalized(
        _ event: AgentJournalEvent,
        aliases: AgentJournalAliasResolver
    ) -> AgentJournalEvent {
        var draft = event.draft
        // A nil resolution means the alias chain hit its cycle cap (corrupt
        // alias state): the current identity is unknowable, so fail closed —
        // strip the target and keep the event as an explicit diagnostic
        // instead of applying state under a possibly stale identity.
        var cycled = false
        if let surfaceId = draft.surfaceId {
            if let resolved = aliases.resolvedSurfaceId(surfaceId) {
                draft.surfaceId = resolved
            } else {
                cycled = true
            }
        }
        if let workspaceId = draft.workspaceId {
            if let resolved = aliases.resolvedWorkspaceId(workspaceId) {
                draft.workspaceId = resolved
            } else {
                cycled = true
            }
        }
        if cycled {
            draft.workspaceId = nil
            draft.surfaceId = nil
            draft.unattributedReason = "alias-cycle"
        }
        return AgentJournalEvent(
            sequence: event.sequence,
            committedAtMs: event.committedAtMs,
            draft: draft
        )
    }

    static func publishUnattributedDiagnostic(_ event: AgentJournalEvent) {
        CmuxEventBus.shared.publish(
            name: "agent.journal.unattributed",
            category: "agent",
            source: "journal",
            payload: [
                "sequence": event.sequence,
                "kind": event.kind.rawValue,
                "agent": event.draft.source,
                "agent_key": event.agentKey,
                "native_event": event.draft.nativeEvent ?? "",
                "reason": event.draft.unattributedReason ?? "missing-surface",
            ]
        )
#if DEBUG
        cmuxDebugLog(
            "agentJournal.unattributed seq=\(event.sequence) kind=\(event.kind.rawValue) " +
                "agent=\(event.draft.source) reason=\(event.draft.unattributedReason ?? "missing-surface")"
        )
#endif
    }

    @MainActor
    static func apply(_ assignment: AgentLifecycleAssignment, workspaceHint: String?) {
        guard AgentHibernationLifecycleStatusKeys.isAllowed(assignment.agentKey) else { return }
        guard let panelId = UUID(uuidString: assignment.surfaceId) else { return }
        let owner: ControlSidebarPanelOwner?
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(panelId) }) {
            owner = .dock(dock)
        } else if let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: workspaceHint.flatMap(UUID.init(uuidString:))
        ) {
            owner = .workspace(located.workspace)
        } else {
            owner = nil
        }
        guard let owner else {
            // Fail closed and record it in release builds too: the panel no
            // longer exists, so the assignment is dropped, never re-homed.
            CmuxEventBus.shared.publish(
                name: "agent.journal.apply_skipped",
                category: "agent",
                source: "journal",
                surfaceId: assignment.surfaceId,
                payload: ["agent_key": assignment.agentKey, "reason": "panelGone"]
            )
#if DEBUG
            cmuxDebugLog(
                "agentJournal.apply.skip surface=\(assignment.surfaceId.prefix(8)) " +
                    "key=\(assignment.agentKey) reason=panelGone"
            )
#endif
            return
        }
        if let phase = assignment.phase {
            owner.setAgentLifecycle(
                key: assignment.agentKey,
                panelId: panelId,
                lifecycle: Self.lifecycle(for: phase)
            )
        } else {
            owner.clearAgentLifecycle(key: assignment.agentKey, panelId: panelId)
        }
#if DEBUG
        cmuxDebugLog(
            "agentJournal.apply surface=\(assignment.surfaceId.prefix(8)) " +
                "key=\(assignment.agentKey) phase=\(assignment.phase?.rawValue ?? "clear")"
        )
#endif
    }

    /// Projects the journal phase onto the sidebar's lifecycle enum. The
    /// sidebar has no dedicated error rendering yet, so `error` uses the
    /// needs-input treatment (matching the pre-journal pipeline) while the
    /// journal retains the honest phase.
    static func lifecycle(for phase: AgentLifecyclePhase) -> AgentHibernationLifecycleState {
        switch phase {
        case .unknown: .unknown
        case .running: .running
        case .needsInput: .needsInput
        case .idle: .idle
        case .error: .needsInput
        }
    }

}
