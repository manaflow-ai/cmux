import CMUXAgentLaunch
import CryptoKit
import Foundation

extension CMUXCLI {
    /// Monotonic budget reserved for the complete asynchronous task hook.
    static let claudeTaskSyncResponseBudgetSeconds: TimeInterval = 8
    /// Short lease budget for SessionEnd to join an in-flight task hook.
    static let claudeSessionEndTaskSyncLockBudgetSeconds: TimeInterval = 1

    /// Whether one parsed CLI invocation is the Claude task-sync hook.
    static func isClaudeTaskSyncHookCommand(
        command: String,
        commandArgs: [String]
    ) -> Bool {
        switch command.lowercased() {
        case "claude-hook":
            return commandArgs.first?.lowercased() == "task-sync"
        case "hooks":
            return commandArgs.first?.lowercased() == "claude"
                && commandArgs.dropFirst().first?.lowercased() == "task-sync"
        default:
            return false
        }
    }

    /// Reconciles Claude Code's per-file task store into cmux's two todo views.
    ///
    /// A full filesystem snapshot is published to both Feed and the workspace
    /// checklist so neither consumer has to reimplement TaskCreate/TaskUpdate
    /// accumulation semantics.
    func runClaudeTaskSyncHook(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        routing: ClaudeHookRoutingContext,
        socketPassword: String?,
        markFeedTelemetryHandled: () -> Void
    ) {
        telemetry.breadcrumb("claude-hook.task-sync")
        markFeedTelemetryHandled()
        // The shared CLI path installs this before socket setup. Retain that
        // original deadline here; direct callers still receive the same bound.
        let hookDeadlineUptime = client.enforceResponseDeadline(
            untilUptime: ProcessInfo.processInfo.systemUptime
                + Self.claudeTaskSyncResponseBudgetSeconds
        )
        sessionStore.enforceLockDeadline(untilUptime: hookDeadlineUptime)

        guard let sessionID = nonEmptyClaudeHookIdentifier(parsedInput.sessionId) else {
            telemetry.breadcrumb("claude-hook.task-sync.missing-session")
            printClaudeHookAck()
            return
        }

        do {
            let mappedSession = try? sessionStore.lookup(sessionId: sessionID)
            var taskRouting = routing
            taskRouting.allowsPidProbe = false
            guard let resolvedTarget = try resolveClaudeHookDeliveryTarget(
                mappedSession: mappedSession,
                routing: taskRouting,
                client: client
            ), resolvedTarget.isAuthoritative else {
                telemetry.breadcrumb("claude-hook.task-sync.unresolved")
                printClaudeHookAck()
                return
            }

            let environment = ProcessInfo.processInfo.environment
            let configuredTaskListID = environment["CLAUDE_CODE_TASK_LIST_ID"].flatMap {
                $0.isEmpty ? nil : $0
            }
            let taskRootResolver = ClaudeTaskRootResolver(
                environment: environment,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
            )
            let tasksRootURL = taskRootResolver.resolve()
            let teamsRootURL = taskRootResolver.resolveTeamsRoot()
            let loader = ClaudeTaskSnapshotLoader(
                tasksRootURL: tasksRootURL,
                deadlineUptime: hookDeadlineUptime
            )
            let configuredTaskDirectoryName = configuredTaskListID.flatMap {
                loader.canonicalDirectoryName(forTaskListID: $0)
            }
            let deletedTeamTaskDirectoryName = claudeTeamDeleteTaskDirectoryName(
                from: parsedInput,
                loader: loader
            )
            let taskStoreIdentity = ClaudeTaskStoreIdentity(
                tasksRootURL: tasksRootURL
            )
            let agentID = nonEmptyClaudeHookIdentifier(
                parsedInput.rawObject?["agent_id"] as? String
            )
            let taskIdentity = claudeTaskIdentity(from: parsedInput.rawObject)
            var coalescingTaskListID = deletedTeamTaskDirectoryName
                ?? configuredTaskDirectoryName
            let taskSyncLockScope = taskStoreIdentity.rawValue
            let taskSyncScanIdentity = Data(
                "\(sessionID.utf8.count):\(sessionID)\((agentID ?? "").utf8.count):\(agentID ?? "")".utf8
            ).base64EncodedString()
            // Agent-qualified hooks are Claude's shared-team mutations; keep
            // their expensive first identity scan single-flight. Unqualified
            // hooks may be independent personal sessions, so retain a
            // per-session scan scope until their owner is known.
            let usesSharedTeamScan = agentID != nil
            let taskSyncScanScope = usesSharedTeamScan
                ? taskSyncLockScope + ":<task-sync-scan>"
                : taskSyncLockScope + ":<task-sync-scan>:" + taskSyncScanIdentity
            let initialCoalescingScope = coalescingTaskListID.map {
                taskSyncLockScope + ":" + $0
            } ?? taskSyncScanScope
            var activeTaskSyncClaim: (scope: String, token: String)?
            do {
                let initialTaskSyncToken = try sessionStore.claimClaudeTaskSync(
                    scope: initialCoalescingScope
                )
                activeTaskSyncClaim = (initialCoalescingScope, initialTaskSyncToken)
            } catch let error as POSIXError where error.code == .E2BIG {
                // Reserve one deterministic overflow slot so saturation keeps
                // one bounded worker instead of queueing unbounded full scans.
                let overflowScope = taskSyncLockScope + ":<task-sync-overflow>"
                guard let overflowToken = try? sessionStore.claimClaudeTaskSync(
                    scope: overflowScope
                ) else {
                    telemetry.breadcrumb("claude-hook.task-sync.coalesce-capacity")
                    printClaudeHookAck()
                    return
                }
                activeTaskSyncClaim = (overflowScope, overflowToken)
                telemetry.breadcrumb("claude-hook.task-sync.coalesce-overflow")
            } catch {
                telemetry.breadcrumb(
                    "claude-hook.task-sync.coalesce-claim-failed",
                    data: ["error": String(describing: error)]
                )
                printClaudeHookAck()
                return
            }
            defer {
                if let activeTaskSyncClaim {
                    try? sessionStore.finishClaudeTaskSync(
                        scope: activeTaskSyncClaim.scope,
                        token: activeTaskSyncClaim.token
                    )
                }
            }
            let taskSyncIsLatest = {
                guard let activeTaskSyncClaim else { return true }
                return (try? sessionStore.isLatestClaudeTaskSync(
                    scope: activeTaskSyncClaim.scope,
                    token: activeTaskSyncClaim.token
                )) == true
            }
            let retargetTaskSyncClaim: (String) throws -> Bool = { taskListID in
                let normalizedTaskListID = taskListID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !normalizedTaskListID.isEmpty else { return false }
                guard let currentClaim = activeTaskSyncClaim else { return true }
                let ownerScope = taskSyncLockScope + ":" + normalizedTaskListID
                if currentClaim.scope.hasSuffix(":<task-sync-overflow>") {
                    guard try sessionStore.transferClaudeTaskSyncClaim(
                        fromScope: currentClaim.scope,
                        toScope: ownerScope,
                        token: currentClaim.token
                    ) else { return false }
                    activeTaskSyncClaim = (ownerScope, currentClaim.token)
                    return true
                }
                guard ownerScope != currentClaim.scope else { return true }
                guard try sessionStore.transferClaudeTaskSyncClaim(
                    fromScope: currentClaim.scope,
                    toScope: ownerScope,
                    token: currentClaim.token
                ) else { return false }
                activeTaskSyncClaim = (ownerScope, currentClaim.token)
                return true
            }
            // Nested teammates mutate the same authoritative task list. Their
            // task hooks must publish it even though other visible mutations
            // stay suppressed; live routing was already validated above, while
            // the resolved list identity owns shared synchronization.
            // Claude starts async hooks as independent CLI processes, which a
            // Swift actor cannot serialize. The durable-store-scoped lock spans
            // every configured Claude root: a later hook reads the latest files
            // only after the earlier snapshot and ownership transition finish.
            try sessionStore.withClaudeTaskSyncLock(
                deadlineUptime: hookDeadlineUptime,
                scope: taskSyncLockScope
            ) {
                guard taskSyncIsLatest() else {
                    telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                    return
                }
                let currentRecord = try sessionStore.lookup(sessionId: sessionID)
                if isClaudeTeamDeleteHook(parsedInput) {
                    if let deletionTaskDirectoryName = deletedTeamTaskDirectoryName
                        ?? configuredTaskDirectoryName {
                        let matchingRecord = try sessionStore.claudeTeamTaskBindingRecord(
                            taskListID: deletionTaskDirectoryName,
                            taskStoreIdentity: taskStoreIdentity
                        )
                        let teamTaskResolver = ClaudeTeamTaskListResolver(
                            teamsRootURL: teamsRootURL,
                            taskStoreIdentity: taskStoreIdentity,
                            deadlineUptime: hookDeadlineUptime
                        )
                        let currentTeamBinding: ClaudeTeamTaskListBinding?
                        if matchingRecord != nil {
                            currentTeamBinding = try teamTaskResolver.currentTaskListBinding(
                                forTaskListID: deletionTaskDirectoryName
                            )
                        } else {
                            currentTeamBinding = nil
                        }
                        if let matchingRecord,
                           matchingRecord.binding.taskStoreIdentity != nil,
                           let currentTeamBinding,
                           !matchingRecord.binding.matches(
                               sessionID: sessionID,
                               agentID: agentID
                           ),
                           !currentTeamBinding.matches(
                               sessionID: sessionID,
                               agentID: agentID
                           ) {
                            // TeamDelete identifies the owner that was deleted,
                            // while the durable task-list key may already hold
                            // a replacement team. Legacy proofs intentionally
                            // allow a replacement caller during migration;
                            // namespaced proofs must retain their owner proof.
                            telemetry.breadcrumb("claude-hook.task-sync.team-delete-reused")
                            return
                        }
                        if let matchingRecord,
                           let currentTeamBinding,
                           try teamTaskResolver.taskListBindingWasReused(
                               matchingRecord.binding,
                               capturedCurrentBinding: currentTeamBinding
                           ) {
                            telemetry.breadcrumb("claude-hook.task-sync.team-delete-reused")
                            return
                        }
                        let destinationRecord = try sessionStore.claudeTaskListDestinationRecord(
                            taskListID: deletionTaskDirectoryName,
                            taskStoreIdentity: taskStoreIdentity
                        )
                        let cleanupTaskDirectoryName = matchingRecord?.binding.taskListID
                            ?? destinationRecord?.taskListID
                            ?? deletionTaskDirectoryName
                        let cleanupWorkspaceIDs = Set(
                            (matchingRecord?.workspaceIDs ?? [])
                                + (destinationRecord?.workspaceIDs ?? [])
                                + [resolvedTarget.workspaceId]
                        ).sorted()
                        guard sendClaudeTaskFeedSnapshot(
                            [],
                            client: client,
                            telemetry: telemetry,
                            parsedInput: parsedInput,
                            workspaceId: resolvedTarget.workspaceId,
                            surfaceId: resolvedTarget.surfaceId,
                            socketPassword: socketPassword,
                            deadlineUptime: hookDeadlineUptime
                        ) else { return }
                        guard try clearLegacyClaudeTaskChecklistOwnerIfNeeded(
                            taskDirectoryName: cleanupTaskDirectoryName,
                            sessionStore: sessionStore,
                            client: client,
                            telemetry: telemetry,
                            workspaceIDs: cleanupWorkspaceIDs,
                            includeFallbackDestinations: true,
                            deadlineUptime: hookDeadlineUptime
                        ) else { return }
                        var cleanupTaskStoreIdentities = Set<ClaudeTaskStoreIdentity?>()
                        if let matchingRecord {
                            cleanupTaskStoreIdentities.insert(
                                matchingRecord.binding.taskStoreIdentity
                            )
                        }
                        if let destinationRecord {
                            cleanupTaskStoreIdentities.insert(
                                destinationRecord.taskStoreIdentity
                            )
                        }
                        if cleanupTaskStoreIdentities.isEmpty {
                            cleanupTaskStoreIdentities.insert(taskStoreIdentity)
                        }
                        var cleanup = (
                            succeeded: true,
                            retainedWorkspaceIDs: cleanupWorkspaceIDs
                        )
                        for cleanupTaskStoreIdentity in cleanupTaskStoreIdentities.sorted(by: {
                            ($0?.rawValue ?? "") < ($1?.rawValue ?? "")
                        }) {
                            cleanup = clearClaudeTaskChecklistOwner(
                                taskDirectoryName: cleanupTaskDirectoryName,
                                taskStoreIdentity: cleanupTaskStoreIdentity,
                                client: client,
                                telemetry: telemetry,
                                workspaceIDs: cleanup.retainedWorkspaceIDs,
                                deadlineUptime: hookDeadlineUptime
                            )
                            guard cleanup.succeeded else { break }
                        }
                        if cleanup.succeeded {
                            for cleanupTaskStoreIdentity in cleanupTaskStoreIdentities {
                                try sessionStore.clearClaudeTaskDirectoryBindings(
                                    directoryName: cleanupTaskDirectoryName,
                                    taskStoreIdentity: cleanupTaskStoreIdentity
                                )
                            }
                        }
                        if let matchingRecord {
                            try sessionStore.retainClaudeTeamTaskBindingWorkspaces(
                                cleanup.retainedWorkspaceIDs,
                                for: matchingRecord.binding
                            )
                            if cleanup.succeeded {
                                try sessionStore.removeClaudeTeamTaskListBinding(
                                    matchingRecord.binding
                                )
                            }
                        }
                        if let destinationRecord {
                            if cleanup.succeeded {
                                try sessionStore.removeClaudeTaskListDestinationRecord(
                                    destinationRecord
                                )
                            } else {
                                try sessionStore.retainClaudeTaskListDestinations(
                                    cleanup.retainedWorkspaceIDs,
                                    for: destinationRecord
                                )
                            }
                        }
                    } else if let previouslyBoundRecord = try sessionStore
                        .claudeTeamTaskBindingRecord(
                            sessionId: sessionID,
                            agentId: agentID,
                            taskStoreIdentity: taskStoreIdentity
                        ) {
                        let cleanupWorkspaceIDs = previouslyBoundRecord.workspaceIDs.isEmpty
                            ? [resolvedTarget.workspaceId]
                            : previouslyBoundRecord.workspaceIDs
                        guard try retargetTaskSyncClaim(
                            previouslyBoundRecord.binding.taskListID
                        ) else {
                            telemetry.breadcrumb("claude-hook.task-sync.coalesce-transfer-failed")
                            return
                        }
                        guard taskSyncIsLatest() else {
                            telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                            return
                        }
                        guard sendClaudeTaskFeedSnapshot(
                            [],
                            client: client,
                            telemetry: telemetry,
                            parsedInput: parsedInput,
                            workspaceId: resolvedTarget.workspaceId,
                            surfaceId: resolvedTarget.surfaceId,
                            socketPassword: socketPassword,
                            deadlineUptime: hookDeadlineUptime
                        ) else { return }
                        let cleanup = clearClaudeTaskChecklistOwner(
                            taskDirectoryName: previouslyBoundRecord.binding.taskListID,
                            taskStoreIdentity: previouslyBoundRecord.binding.taskStoreIdentity,
                            client: client,
                            telemetry: telemetry,
                            workspaceIDs: cleanupWorkspaceIDs,
                            deadlineUptime: hookDeadlineUptime
                        )
                        try sessionStore.retainClaudeTeamTaskBindingWorkspaces(
                            cleanup.retainedWorkspaceIDs,
                            for: previouslyBoundRecord.binding
                        )
                        if cleanup.succeeded {
                            try sessionStore.clearClaudeTaskDirectoryBindings(
                                directoryName: previouslyBoundRecord.binding.taskListID,
                                taskStoreIdentity: previouslyBoundRecord.binding.taskStoreIdentity
                            )
                            try sessionStore.removeClaudeTeamTaskListBinding(
                                previouslyBoundRecord.binding
                            )
                        }
                    }
                    return
                }

                if let configuredTaskListID {
                    guard let snapshot = try loader.loadKnownTaskList(
                        taskListID: configuredTaskListID
                    ) else {
                        telemetry.breadcrumb("claude-hook.task-sync.task-directory-unresolved")
                        return
                    }
                    let matchingTeamRecord = try sessionStore.claudeTeamTaskBindingRecord(
                        taskListID: snapshot.directoryName,
                        taskStoreIdentity: taskStoreIdentity
                    )
                    let destinationTransition = try sessionStore
                        .claudeTaskListDestinationTransition(
                            taskListID: snapshot.directoryName,
                            taskStoreIdentity: taskStoreIdentity,
                            including: (matchingTeamRecord?.workspaceIDs ?? [])
                                + [resolvedTarget.workspaceId]
                        )
                    let destinationWorkspaceIDs = destinationTransition.workspaceIDs
                    guard try migrateLegacyClaudeTaskChecklistOwnerIfNeeded(
                        currentRecord: currentRecord,
                        sessionID: sessionID,
                        taskDirectoryName: snapshot.directoryName,
                        taskStoreIdentity: taskStoreIdentity,
                        sessionStore: sessionStore,
                        client: client,
                        telemetry: telemetry,
                        workspaceIDs: destinationWorkspaceIDs,
                        deadlineUptime: hookDeadlineUptime
                    ) else { return }
                    guard try retargetTaskSyncClaim(snapshot.directoryName) else {
                        telemetry.breadcrumb("claude-hook.task-sync.coalesce-transfer-failed")
                        return
                    }
                    guard taskSyncIsLatest() else {
                        telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                        return
                    }
                    guard let delivery = deliverClaudeTaskSnapshot(
                        snapshot,
                        taskStoreIdentity: taskStoreIdentity,
                        client: client,
                        telemetry: telemetry,
                        parsedInput: parsedInput,
                        workspaceId: resolvedTarget.workspaceId,
                        surfaceId: resolvedTarget.surfaceId,
                        reconciliationWorkspaceIDs: destinationWorkspaceIDs,
                        socketPassword: socketPassword,
                        deadlineUptime: hookDeadlineUptime
                    ) else { return }
                    guard try clearRetiredClaudeTaskListDestinations(
                        destinationTransition.retiredRecords,
                        sessionStore: sessionStore,
                        client: client,
                        telemetry: telemetry,
                        deadlineUptime: hookDeadlineUptime
                    ) else { return }
                    try persistClaudeTaskListDestinations(
                        taskDirectoryName: snapshot.directoryName,
                        taskStoreIdentity: taskStoreIdentity,
                        retainedWorkspaceIDs: delivery.retainedWorkspaceIDs,
                        sessionStore: sessionStore
                    )
                    return
                }

                let previouslyBoundRecord = try sessionStore.claudeTeamTaskBindingRecord(
                    sessionId: sessionID,
                    agentId: agentID,
                    taskStoreIdentity: taskStoreIdentity
                )
                let previouslyBoundBinding = previouslyBoundRecord?.binding

                // Team membership is authoritative and task IDs are only unique
                // within one list. The bounded config scan must therefore run
                // before accepting an identity collision in the personal store.
                let automaticTeamResolution = try ClaudeTeamTaskListResolver(
                    teamsRootURL: teamsRootURL,
                    taskStoreIdentity: taskStoreIdentity,
                    deadlineUptime: hookDeadlineUptime
                ).resolveTaskListBinding(
                    sessionID: sessionID,
                    agentID: agentID,
                    previouslyBoundBinding: previouslyBoundBinding
                )
                if let automaticTeamResolution {
                    guard try retargetTaskSyncClaim(
                        automaticTeamResolution.binding.taskListID
                    ) else {
                        telemetry.breadcrumb("claude-hook.task-sync.coalesce-transfer-failed")
                        return
                    }
                    guard taskSyncIsLatest() else {
                        telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                        return
                    }
                }
                if let automaticTeamResolution,
                   !automaticTeamResolution.usesRetainedCleanupProof {
                    guard let snapshot = try loader.loadKnownTaskList(
                        taskListID: automaticTeamResolution.binding.taskListID
                    ) else {
                        telemetry.breadcrumb("claude-hook.task-sync.task-directory-unresolved")
                        return
                    }
                    let transition = try sessionStore.claudeTeamTaskBindingTransition(
                        automaticTeamResolution.binding,
                        workspaceId: resolvedTarget.workspaceId
                    )
                    for retiredRecord in transition.retiredRecords {
                        let retiredWorkspaceIDs = retiredRecord.workspaceIDs.isEmpty
                            ? [resolvedTarget.workspaceId]
                            : retiredRecord.workspaceIDs
                        guard clearClaudeTaskChecklistOwner(
                            taskDirectoryName: retiredRecord.binding.taskListID,
                            taskStoreIdentity: retiredRecord.binding.taskStoreIdentity,
                            client: client,
                            telemetry: telemetry,
                            workspaceIDs: retiredWorkspaceIDs,
                            deadlineUptime: hookDeadlineUptime
                        ).succeeded else { return }
                    }
                    let teamWorkspaceIDs = try sessionStore.commitClaudeTeamTaskListBinding(
                        automaticTeamResolution.binding,
                        workspaceIDs: transition.workspaceIDs,
                        retiredRecords: transition.retiredRecords
                    )
                    guard try migrateLegacyClaudeTaskChecklistOwnerIfNeeded(
                        currentRecord: currentRecord,
                        sessionID: sessionID,
                        taskDirectoryName: snapshot.directoryName,
                        taskStoreIdentity: taskStoreIdentity,
                        sessionStore: sessionStore,
                        client: client,
                        telemetry: telemetry,
                        workspaceIDs: teamWorkspaceIDs,
                        deadlineUptime: hookDeadlineUptime
                    ) else { return }
                    guard taskSyncIsLatest() else {
                        telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                        return
                    }
                    guard let delivery = deliverClaudeTaskSnapshot(
                        snapshot,
                        taskStoreIdentity: taskStoreIdentity,
                        client: client,
                        telemetry: telemetry,
                        parsedInput: parsedInput,
                        workspaceId: resolvedTarget.workspaceId,
                        surfaceId: resolvedTarget.surfaceId,
                        reconciliationWorkspaceIDs: teamWorkspaceIDs,
                        socketPassword: socketPassword,
                        deadlineUptime: hookDeadlineUptime
                    ) else { return }
                    try sessionStore.retainClaudeTeamTaskBindingWorkspaces(
                        delivery.retainedWorkspaceIDs,
                        for: automaticTeamResolution.binding
                    )
                    return
                }

                var cleanupTaskDirectoryName: String?
                var deferredAutomaticTeamCleanup: (
                    binding: ClaudeTeamTaskListBinding,
                    workspaceIDs: [String]
                )?
                if let automaticTeamResolution {
                    cleanupTaskDirectoryName = automaticTeamResolution.binding.taskListID
                    let cleanupWorkspaceIDs: [String]
                    if let recordedWorkspaceIDs = previouslyBoundRecord?.workspaceIDs,
                       !recordedWorkspaceIDs.isEmpty {
                        cleanupWorkspaceIDs = recordedWorkspaceIDs
                    } else {
                        cleanupWorkspaceIDs = [resolvedTarget.workspaceId]
                    }
                    if sendClaudeTaskFeedSnapshot(
                        [],
                        client: client,
                        telemetry: telemetry,
                        parsedInput: parsedInput,
                        workspaceId: resolvedTarget.workspaceId,
                        surfaceId: resolvedTarget.surfaceId,
                        socketPassword: socketPassword,
                        deadlineUptime: hookDeadlineUptime
                    ) {
                        let cleanupSucceeded = (try? clearRetainedClaudeTeamTaskOwner(
                            binding: automaticTeamResolution.binding,
                            workspaceIDs: cleanupWorkspaceIDs,
                            retirementTaskStoreIdentity: taskStoreIdentity,
                            sessionStore: sessionStore,
                            client: client,
                            telemetry: telemetry,
                            deadlineUptime: hookDeadlineUptime
                        )) == true
                        if !cleanupSucceeded {
                            deferredAutomaticTeamCleanup = (
                                automaticTeamResolution.binding,
                                cleanupWorkspaceIDs
                            )
                        }
                    } else {
                        // A personal snapshot can supersede the rejected empty
                        // Feed update. Defer checklist cleanup until that
                        // authoritative replacement is acknowledged below.
                        deferredAutomaticTeamCleanup = (
                            automaticTeamResolution.binding,
                            cleanupWorkspaceIDs
                        )
                    }
                    // A retained team proof owns only the old cleanup delivery.
                    // The same hook may already describe the leader's first new
                    // personal task, so continue through session-owned resolution.
                }

                // An agent-qualified hook must prove automatic-team membership;
                // the leader session alone is intentionally not sufficient.
                guard agentID == nil else {
                    telemetry.breadcrumb("claude-hook.task-sync.unproven-agent")
                    return
                }
                guard shouldApplyClaudeHookVisibleMutation(
                    sessionStore: sessionStore,
                    parsedInput: parsedInput,
                    workspaceId: resolvedTarget.workspaceId,
                    surfaceId: resolvedTarget.isAuthoritative ? resolvedTarget.surfaceId : nil,
                    telemetry: telemetry
                ) else {
                    telemetry.breadcrumb("claude-hook.task-sync.stale")
                    return
                }

                var sessionSnapshot = try loader.loadDirectSessionTaskList(
                    sessionID: sessionID,
                    taskIdentity: taskIdentity
                )
                if sessionSnapshot == nil {
                    let boundDirectoryName = currentRecord?.claudeTaskStoreID
                        == taskStoreIdentity.rawValue
                        ? currentRecord?.claudeTaskDirectoryName
                        : nil
                    if let boundDirectoryName {
                        sessionSnapshot = try loader.loadBoundTaskList(
                            directoryName: boundDirectoryName,
                            taskIdentity: taskIdentity
                        )
                    } else if let taskIdentity {
                        // Older Claude team metadata may not link the current
                        // hook session to its task list. The issue contract's
                        // compatibility proof is the exact id+subject emitted
                        // by this hook; the bounded loader fails closed when
                        // more than one directory contains that same tuple.
                        sessionSnapshot = try loader.load(
                            sessionID: sessionID,
                            taskIdentity: taskIdentity
                        )
                    }
                }
                guard let sessionSnapshot,
                      sessionSnapshot.directoryName != cleanupTaskDirectoryName else {
                    telemetry.breadcrumb("claude-hook.task-sync.task-directory-unresolved")
                    return
                }
                guard try !sessionStore.isClaudeTaskListRetired(
                    taskListID: sessionSnapshot.directoryName,
                    taskStoreIdentity: taskStoreIdentity
                ) else {
                    telemetry.breadcrumb("claude-hook.task-sync.retired-task-directory")
                    return
                }
                guard try retargetTaskSyncClaim(sessionSnapshot.directoryName) else {
                    telemetry.breadcrumb("claude-hook.task-sync.coalesce-transfer-failed")
                    return
                }
                guard taskSyncIsLatest() else {
                    telemetry.breadcrumb("claude-hook.task-sync.coalesced")
                    return
                }
                let personalFeedAlreadyPublished: Bool
                if deferredAutomaticTeamCleanup != nil {
                    guard sendClaudeTaskFeedSnapshot(
                        sessionSnapshot.todos,
                        client: client,
                        telemetry: telemetry,
                        parsedInput: parsedInput,
                        workspaceId: resolvedTarget.workspaceId,
                        surfaceId: resolvedTarget.surfaceId,
                        socketPassword: socketPassword,
                        deadlineUptime: hookDeadlineUptime
                    ) else { return }
                    personalFeedAlreadyPublished = true
                } else {
                    personalFeedAlreadyPublished = false
                }
                let destinationTransition = try sessionStore
                    .claudeTaskListDestinationTransition(
                        taskListID: sessionSnapshot.directoryName,
                        taskStoreIdentity: taskStoreIdentity,
                        including: [resolvedTarget.workspaceId]
                    )
                guard try migrateLegacyClaudeTaskChecklistOwnerIfNeeded(
                    currentRecord: currentRecord,
                    sessionID: sessionID,
                    taskDirectoryName: sessionSnapshot.directoryName,
                    taskStoreIdentity: taskStoreIdentity,
                    sessionStore: sessionStore,
                    client: client,
                    telemetry: telemetry,
                    workspaceIDs: [resolvedTarget.workspaceId],
                    deadlineUptime: hookDeadlineUptime
                ) else { return }
                let delivery: (
                    reconciliationSucceeded: Bool,
                    workspaceItemsAreEmpty: Bool,
                    retainedWorkspaceIDs: [String]
                )?
                if personalFeedAlreadyPublished {
                    delivery = reconcileClaudeTaskSnapshot(
                        sessionSnapshot,
                        taskStoreIdentity: taskStoreIdentity,
                        client: client,
                        telemetry: telemetry,
                        reconciliationWorkspaceIDs: [resolvedTarget.workspaceId],
                        deadlineUptime: hookDeadlineUptime
                    )
                } else {
                    delivery = deliverClaudeTaskSnapshot(
                        sessionSnapshot,
                        taskStoreIdentity: taskStoreIdentity,
                        client: client,
                        telemetry: telemetry,
                        parsedInput: parsedInput,
                        workspaceId: resolvedTarget.workspaceId,
                        surfaceId: resolvedTarget.surfaceId,
                        reconciliationWorkspaceIDs: [resolvedTarget.workspaceId],
                        socketPassword: socketPassword,
                        deadlineUptime: hookDeadlineUptime
                    )
                }
                guard let delivery else { return }
                let retainedPersonalWorkspaceIDs = delivery.workspaceItemsAreEmpty
                    && delivery.reconciliationSucceeded
                    ? []
                    : delivery.retainedWorkspaceIDs
                let normalizedWorkspaceID = resolvedTarget.workspaceId.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard delivery.reconciliationSucceeded,
                      delivery.retainedWorkspaceIDs.contains(normalizedWorkspaceID) else {
                    return
                }
                guard try clearRetiredClaudeTaskListDestinations(
                    destinationTransition.retiredRecords,
                    sessionStore: sessionStore,
                    client: client,
                    telemetry: telemetry,
                    deadlineUptime: hookDeadlineUptime
                ) else { return }
                guard clearSupersededPersonalClaudeTaskChecklistOwnerIfNeeded(
                    currentRecord: currentRecord,
                    taskDirectoryName: sessionSnapshot.directoryName,
                    taskStoreIdentity: taskStoreIdentity,
                    currentWorkspaceID: resolvedTarget.workspaceId,
                    recordedWorkspaceIDs: destinationTransition.workspaceIDs,
                    client: client,
                    telemetry: telemetry,
                    deadlineUptime: hookDeadlineUptime
                ) else { return }
                guard try sessionStore.bindClaudeTaskDirectory(
                    sessionId: sessionID,
                    directoryName: sessionSnapshot.directoryName,
                    taskStoreIdentity: taskStoreIdentity,
                    workspaceId: resolvedTarget.workspaceId,
                    surfaceId: resolvedTarget.surfaceId,
                    expectedStartedAt: currentRecord?.startedAt
                ) else {
                    telemetry.breadcrumb("claude-hook.task-sync.session-ended")
                    if (try? sessionStore.isClaudeSessionEnded(sessionID)) == true {
                        _ = clearClaudeTaskChecklistOwner(
                            taskDirectoryName: sessionSnapshot.directoryName,
                            taskStoreIdentity: taskStoreIdentity,
                            client: client,
                            telemetry: telemetry,
                            workspaceIDs: delivery.retainedWorkspaceIDs,
                            deadlineUptime: hookDeadlineUptime
                        )
                    }
                    return
                }
                try sessionStore.unretireClaudeTaskList(
                    taskListID: sessionSnapshot.directoryName,
                    taskStoreIdentity: taskStoreIdentity
                )
                try persistClaudeTaskListDestinations(
                    taskDirectoryName: sessionSnapshot.directoryName,
                    taskStoreIdentity: taskStoreIdentity,
                    retainedWorkspaceIDs: retainedPersonalWorkspaceIDs,
                    sessionStore: sessionStore
                )
                if let deferredAutomaticTeamCleanup {
                    // The personal replacement is durable before the
                    // superseded team owner is retried. Keep the old proof
                    // when cleanup fails so a later hook can retry without
                    // stranding the accepted personal binding.
                    let cleanupSucceeded = (try? clearRetainedClaudeTeamTaskOwner(
                        binding: deferredAutomaticTeamCleanup.binding,
                        workspaceIDs: deferredAutomaticTeamCleanup.workspaceIDs,
                        retirementTaskStoreIdentity: taskStoreIdentity,
                        sessionStore: sessionStore,
                        client: client,
                        telemetry: telemetry,
                        deadlineUptime: hookDeadlineUptime
                    )) == true
                    if !cleanupSucceeded {
                        telemetry.breadcrumb(
                            "claude-hook.task-sync.deferred-team-cleanup-failed"
                        )
                    }
                }
            }
        } catch {
            telemetry.breadcrumb(
                "claude-hook.task-sync.error",
                data: ["error": String(describing: error)]
            )
        }
        printClaudeHookAck()
    }

    /// Clears every proven prior personal destination after its replacement succeeds.
    private func clearSupersededPersonalClaudeTaskChecklistOwnerIfNeeded(
        currentRecord: ClaudeHookSessionRecord?,
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        currentWorkspaceID: String,
        recordedWorkspaceIDs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        deadlineUptime: TimeInterval
    ) -> Bool {
        let normalizedCurrentWorkspaceID = currentWorkspaceID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedCurrentWorkspaceID.isEmpty else { return false }
        var workspaceIDsByTaskDirectory: [String: Set<String>] = [:]
        for recordedWorkspaceID in recordedWorkspaceIDs {
            let normalizedWorkspaceID = recordedWorkspaceID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !normalizedWorkspaceID.isEmpty,
               normalizedWorkspaceID != normalizedCurrentWorkspaceID {
                workspaceIDsByTaskDirectory[taskDirectoryName, default: []]
                    .insert(normalizedWorkspaceID)
            }
        }
        if let currentRecord,
           let previousTaskDirectoryName = currentRecord.claudeTaskDirectoryName,
           currentRecord.claudeTaskStoreID == taskStoreIdentity.rawValue {
            let previousWorkspaceID = currentRecord.workspaceId.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !previousWorkspaceID.isEmpty,
               previousTaskDirectoryName != taskDirectoryName
                || previousWorkspaceID != normalizedCurrentWorkspaceID {
                workspaceIDsByTaskDirectory[previousTaskDirectoryName, default: []]
                    .insert(previousWorkspaceID)
            }
        }
        for taskDirectory in workspaceIDsByTaskDirectory.keys.sorted() {
            guard let workspaceIDs = workspaceIDsByTaskDirectory[taskDirectory],
                  clearClaudeTaskChecklistOwner(
                    taskDirectoryName: taskDirectory,
                    taskStoreIdentity: taskStoreIdentity,
                    client: client,
                    telemetry: telemetry,
                    workspaceIDs: workspaceIDs.sorted(),
                    deadlineUptime: deadlineUptime
                  ).succeeded else { return false }
        }
        return true
    }

    /// Clears bounded task-list proofs selected for durable-store retirement.
    private func clearRetiredClaudeTaskListDestinations(
        _ retiredRecords: [ClaudeHookTaskListDestinationRecord],
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        for retiredRecord in retiredRecords {
            guard !retiredRecord.workspaceIDs.isEmpty else {
                try sessionStore.removeClaudeTaskListDestinationRecord(retiredRecord)
                continue
            }
            let cleanup = clearClaudeTaskChecklistOwner(
                taskDirectoryName: retiredRecord.taskListID,
                taskStoreIdentity: retiredRecord.taskStoreIdentity,
                client: client,
                telemetry: telemetry,
                workspaceIDs: retiredRecord.workspaceIDs,
                deadlineUptime: deadlineUptime
            )
            if cleanup.succeeded {
                try sessionStore.removeClaudeTaskListDestinationRecord(retiredRecord)
            } else {
                try sessionStore.retainClaudeTaskListDestinations(
                    cleanup.retainedWorkspaceIDs,
                    for: retiredRecord
                )
                return false
            }
        }
        return true
    }

    /// Persists only destinations that may still carry one task-list owner.
    private func persistClaudeTaskListDestinations(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        retainedWorkspaceIDs: [String],
        sessionStore: ClaudeHookSessionStore
    ) throws {
        if !retainedWorkspaceIDs.isEmpty {
            try sessionStore.commitClaudeTaskListDestinations(
                taskListID: taskDirectoryName,
                taskStoreIdentity: taskStoreIdentity,
                workspaceIDs: retainedWorkspaceIDs
            )
        } else if let destinationRecord = try sessionStore
            .claudeTaskListDestinationRecord(
                taskListID: taskDirectoryName,
                taskStoreIdentity: taskStoreIdentity
            ) {
            try sessionStore.removeClaudeTaskListDestinationRecord(destinationRecord)
        }
    }

    /// Retries one retained automatic-team owner and preserves failed destinations.
    private func clearRetainedClaudeTeamTaskOwner(
        binding: ClaudeTeamTaskListBinding,
        workspaceIDs: [String],
        retirementTaskStoreIdentity: ClaudeTaskStoreIdentity,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        let cleanup = clearClaudeTaskChecklistOwner(
            taskDirectoryName: binding.taskListID,
            taskStoreIdentity: binding.taskStoreIdentity,
            client: client,
            telemetry: telemetry,
            workspaceIDs: workspaceIDs,
            deadlineUptime: deadlineUptime
        )
        try sessionStore.retainClaudeTeamTaskBindingWorkspaces(
            cleanup.retainedWorkspaceIDs,
            for: binding
        )
        if cleanup.succeeded {
            try sessionStore.clearClaudeTaskDirectoryBindings(
                directoryName: binding.taskListID,
                taskStoreIdentity: binding.taskStoreIdentity
            )
            if binding.taskStoreIdentity == nil {
                try sessionStore.clearClaudeTaskDirectoryBindings(
                    directoryName: binding.taskListID,
                    taskStoreIdentity: nil
                )
            }
            try sessionStore.retireClaudeTaskList(
                taskListID: binding.taskListID,
                taskStoreIdentity: retirementTaskStoreIdentity
            )
            try sessionStore.removeClaudeTeamTaskListBinding(binding)
        }
        return cleanup.succeeded
    }

    /// Clears one pre-profile owner before namespaced delivery and stamps its proof.
    private func migrateLegacyClaudeTaskChecklistOwnerIfNeeded(
        currentRecord: ClaudeHookSessionRecord?,
        sessionID: String,
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        var legacyDirectoryNames: Set<String> = [taskDirectoryName]
        let currentLegacyDirectoryName: String?
        if currentRecord?.claudeTaskStoreID == nil {
            currentLegacyDirectoryName = currentRecord?.claudeTaskDirectoryName
            if let currentLegacyDirectoryName {
                legacyDirectoryNames.insert(currentLegacyDirectoryName)
            }
        } else {
            currentLegacyDirectoryName = nil
        }
        for legacyDirectoryName in legacyDirectoryNames.sorted() {
            guard try clearLegacyClaudeTaskChecklistOwnerIfNeeded(
                taskDirectoryName: legacyDirectoryName,
                sessionStore: sessionStore,
                client: client,
                telemetry: telemetry,
                workspaceIDs: workspaceIDs
                    + (currentRecord.map { [$0.workspaceId] } ?? []),
                deadlineUptime: deadlineUptime
            ) else { return false }
            if currentLegacyDirectoryName == legacyDirectoryName {
                guard try sessionStore.markLegacyClaudeTaskDirectoryMigrated(
                    sessionId: sessionID,
                    directoryName: legacyDirectoryName,
                    taskStoreIdentity: taskStoreIdentity
                ) else { return false }
            }
        }
        return true
    }

    /// Clears one legacy owner from every recorded destination in bounded batches.
    private func clearLegacyClaudeTaskChecklistOwnerIfNeeded(
        taskDirectoryName: String,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        includeFallbackDestinations: Bool = false,
        deadlineUptime: TimeInterval
    ) throws -> Bool {
        let recordedWorkspaceIDs = try sessionStore.legacyClaudeTaskOwnerWorkspaceIDs(
            directoryName: taskDirectoryName,
            including: workspaceIDs,
            includeFallbackDestinations: includeFallbackDestinations
        )
        guard !recordedWorkspaceIDs.isEmpty else { return true }
        let batchSize = ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount
        for batchStart in stride(
            from: 0,
            to: recordedWorkspaceIDs.count,
            by: batchSize
        ) {
            let batchEnd = min(batchStart + batchSize, recordedWorkspaceIDs.count)
            guard clearClaudeTaskChecklistOwner(
                taskDirectoryName: taskDirectoryName,
                taskStoreIdentity: nil,
                client: client,
                telemetry: telemetry,
                workspaceIDs: Array(recordedWorkspaceIDs[batchStart..<batchEnd]),
                deadlineUptime: deadlineUptime
            ).succeeded else { return false }
        }
        try sessionStore.markLegacyClaudeTaskOwnerCleared(
            directoryName: taskDirectoryName
        )
        return true
    }

    /// Publishes one authoritative task snapshot to Feed and workspace todos.
    private func deliverClaudeTaskSnapshot(
        _ snapshot: ClaudeTaskSnapshot,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String,
        surfaceId: String,
        reconciliationWorkspaceIDs: [String],
        socketPassword: String?,
        deadlineUptime: TimeInterval
    ) -> (
        reconciliationSucceeded: Bool,
        workspaceItemsAreEmpty: Bool,
        retainedWorkspaceIDs: [String]
    )? {
        let todos = snapshot.todos
        guard sendClaudeTaskFeedSnapshot(
            todos,
            client: client,
            telemetry: telemetry,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            socketPassword: socketPassword,
            deadlineUptime: deadlineUptime
        ) else { return nil }

        return reconcileClaudeTaskSnapshot(
            snapshot,
            taskStoreIdentity: taskStoreIdentity,
            client: client,
            telemetry: telemetry,
            reconciliationWorkspaceIDs: reconciliationWorkspaceIDs,
            deadlineUptime: deadlineUptime
        )
    }

    /// Reconciles a task snapshot whose authoritative Feed update is acknowledged.
    private func reconcileClaudeTaskSnapshot(
        _ snapshot: ClaudeTaskSnapshot,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        reconciliationWorkspaceIDs: [String],
        deadlineUptime: TimeInterval
    ) -> (
        reconciliationSucceeded: Bool,
        workspaceItemsAreEmpty: Bool,
        retainedWorkspaceIDs: [String]
    )? {
        guard let checklistOwnerID = claudeTaskChecklistOwnerID(
            taskDirectoryName: snapshot.directoryName,
            taskStoreIdentity: taskStoreIdentity
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.invalid-checklist-owner")
            return nil
        }
        let todos = snapshot.todos

        // Claude removes an all-completed task list on its own grace timer
        // without firing another task-tool hook. Keep the complete snapshot in
        // Feed but clear terminal rows from the workspace progress view.
        let checklistTodos = todos.allSatisfy { $0.state == .completed } ? [] : todos
        let checklistItems = checklistTodos.map {
            claudeTaskChecklistDictionary(
                $0,
                taskDirectoryName: snapshot.directoryName,
                taskStoreIdentity: taskStoreIdentity
            )
        }
        let reconciliation = reconcileClaudeTaskChecklistOwner(
            checklistOwnerID: checklistOwnerID,
            checklistItems: checklistItems,
            client: client,
            telemetry: telemetry,
            workspaceIDs: reconciliationWorkspaceIDs,
            deadlineUptime: deadlineUptime
        )
        return (
            reconciliation.succeeded,
            checklistItems.isEmpty,
            reconciliation.retainedWorkspaceIDs
        )
    }

    private func sendClaudeTaskFeedSnapshot(
        _ todos: [WorkstreamTaskTodo],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String,
        surfaceId: String,
        socketPassword: String?,
        deadlineUptime: TimeInterval
    ) -> Bool {
        let remainingSeconds = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remainingSeconds > 0 else {
            telemetry.breadcrumb("claude-hook.task-sync.deadline-exceeded")
            return false
        }
        let delivered = sendFeedTelemetry(
            client: client,
            source: "claude",
            subcommand: "task-sync",
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            socketPassword: socketPassword,
            delivery: .acknowledged(responseTimeout: min(5, remainingSeconds)),
            toolNameOverride: "TodoWrite",
            toolInputOverride: ["todos": todos.map(claudeTaskFeedDictionary)]
        )
        if !delivered {
            telemetry.breadcrumb("claude-hook.task-sync.feed-delivery-failed")
        }
        return delivered
    }

    private func clearClaudeTaskChecklistOwner(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity?,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        deadlineUptime: TimeInterval
    ) -> (succeeded: Bool, retainedWorkspaceIDs: [String]) {
        guard let checklistOwnerID = claudeTaskChecklistOwnerID(
            taskDirectoryName: taskDirectoryName,
            taskStoreIdentity: taskStoreIdentity
        ) else {
            telemetry.breadcrumb("claude-hook.task-sync.invalid-checklist-owner")
            return (false, workspaceIDs)
        }
        return reconcileClaudeTaskChecklistOwner(
            checklistOwnerID: checklistOwnerID,
            checklistItems: [],
            client: client,
            telemetry: telemetry,
            workspaceIDs: workspaceIDs,
            deadlineUptime: deadlineUptime
        )
    }

    private func reconcileClaudeTaskChecklistOwner(
        checklistOwnerID: String,
        checklistItems: [[String: Any]],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        workspaceIDs: [String],
        deadlineUptime: TimeInterval
    ) -> (succeeded: Bool, retainedWorkspaceIDs: [String]) {
        let destinationWorkspaceIDs = Set(workspaceIDs.compactMap {
            let workspaceID = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return workspaceID.isEmpty ? nil : workspaceID
        }).sorted()
        guard !destinationWorkspaceIDs.isEmpty,
              destinationWorkspaceIDs.count <= ClaudeHookTeamTaskBindingRecord.maximumWorkspaceCount else {
            telemetry.breadcrumb("claude-hook.task-sync.invalid-workspace-destinations")
            return (false, destinationWorkspaceIDs)
        }
        let remainingSeconds = deadlineUptime - ProcessInfo.processInfo.systemUptime
        guard remainingSeconds > 0 else {
            telemetry.breadcrumb("claude-hook.task-sync.deadline-exceeded")
            return (false, destinationWorkspaceIDs)
        }
        let response: [String: Any]
        do {
            response = try client.sendV2(
                method: "workspace.todo.reconcile",
                params: [
                    "workspace_ids": destinationWorkspaceIDs,
                    "owner_id": checklistOwnerID,
                    "items": checklistItems,
                ],
                responseTimeout: min(5, remainingSeconds)
            )
        } catch {
            telemetry.breadcrumb(
                "claude-hook.task-sync.workspace-batch-error",
                data: ["error": String(describing: error)]
            )
            return (false, destinationWorkspaceIDs)
        }
        guard let rawResults = response["results"] as? [[String: Any]] else {
            telemetry.breadcrumb("claude-hook.task-sync.invalid-workspace-results")
            return (false, destinationWorkspaceIDs)
        }
        var resultsByWorkspaceID: [String: [String: Any]] = [:]
        for result in rawResults {
            guard let workspaceID = result["workspace_id"] as? String,
                  destinationWorkspaceIDs.contains(workspaceID),
                  resultsByWorkspaceID.updateValue(result, forKey: workspaceID) == nil else {
                telemetry.breadcrumb("claude-hook.task-sync.invalid-workspace-results")
                return (false, destinationWorkspaceIDs)
            }
        }

        var reconciliationSucceeded = true
        var retainedWorkspaceIDs: [String] = []
        for destinationWorkspaceID in destinationWorkspaceIDs {
            guard let result = resultsByWorkspaceID[destinationWorkspaceID],
                  let succeeded = result["ok"] as? Bool else {
                reconciliationSucceeded = false
                retainedWorkspaceIDs.append(destinationWorkspaceID)
                continue
            }
            if succeeded {
                retainedWorkspaceIDs.append(destinationWorkspaceID)
                continue
            }
            let error = result["error"] as? [String: Any]
            if error?["code"] as? String == "not_found" {
                telemetry.breadcrumb(
                    "claude-hook.task-sync.workspace-retired",
                    data: ["workspace_id": destinationWorkspaceID]
                )
                continue
            }
            reconciliationSucceeded = false
            retainedWorkspaceIDs.append(destinationWorkspaceID)
            telemetry.breadcrumb(
                "claude-hook.task-sync.workspace-error",
                data: [
                    "error": String(describing: error ?? [:]),
                    "workspace_id": destinationWorkspaceID,
                ]
            )
        }
        return (reconciliationSucceeded, retainedWorkspaceIDs)
    }

    private func isClaudeTeamDeleteHook(_ parsedInput: ClaudeHookParsedInput) -> Bool {
        let object = parsedInput.rawObject ?? parsedInput.object
        return object?["tool_name"] as? String == "TeamDelete"
    }

    /// Returns the structured TeamDelete owner independently of ambient environment.
    private func claudeTeamDeleteTaskDirectoryName(
        from parsedInput: ClaudeHookParsedInput,
        loader: ClaudeTaskSnapshotLoader
    ) -> String? {
        guard isClaudeTeamDeleteHook(parsedInput) else { return nil }
        let object = parsedInput.rawObject ?? parsedInput.object
        let input = object?["tool_input"] as? [String: Any]
        guard let teamName = nonEmptyClaudeHookIdentifier(
            input?["team_name"] as? String
        ) else { return nil }
        return loader.canonicalDirectoryName(forTaskListID: teamName)
    }

    /// Extracts the exact task identity from Claude's uncompacted hook payload.
    ///
    /// The compact Feed payload intentionally omits `tool_response`, so task
    /// directory resolution must read the original object retained by the hook
    /// parser. A partial identity is never used for directory selection.
    private func claudeTaskIdentity(from rawObject: [String: Any]?) -> ClaudeTaskIdentity? {
        let input = rawObject?["tool_input"] as? [String: Any]
        // A successful delete removes the identity-bearing task file before
        // PostToolUse runs. Reuse an existing proven binding (or the exact
        // session path) instead of treating that expected absence as a failed
        // ownership proof.
        if input?["status"] as? String == "deleted" {
            return nil
        }
        let responseTask = (rawObject?["tool_response"] as? [String: Any])?["task"] as? [String: Any]
        let eventTask = rawObject?["task"] as? [String: Any]
        let id = responseTask?["id"] as? String
            ?? eventTask?["id"] as? String
            ?? input?["taskId"] as? String
            ?? input?["task_id"] as? String
            ?? rawObject?["taskId"] as? String
            ?? rawObject?["task_id"] as? String
        guard let id,
              !id.isEmpty else { return nil }
        let responseSubject = responseTask?["subject"] as? String
        let eventSubject = eventTask?["subject"] as? String
        let inputSubject = input?["subject"] as? String
        let rawSubject = rawObject?["task_subject"] as? String
        guard let subject = responseSubject ?? eventSubject ?? inputSubject ?? rawSubject,
              !subject.isEmpty else { return nil }
        return ClaudeTaskIdentity(id: id, subject: subject)
    }

    private func claudeTaskFeedDictionary(_ todo: WorkstreamTaskTodo) -> [String: Any] {
        var value: [String: Any] = [
            "id": todo.id,
            "content": todo.content,
            "status": claudeTaskState(todo.state, workspaceWireFormat: false),
        ]
        if let activeForm = todo.activeForm {
            value["activeForm"] = activeForm
        }
        return value
    }

    private func claudeTaskChecklistDictionary(
        _ todo: WorkstreamTaskTodo,
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity
    ) -> [String: Any] {
        [
            "id": claudeTaskChecklistID(
                taskDirectoryName: taskDirectoryName,
                taskStoreIdentity: taskStoreIdentity,
                taskID: todo.id
            ).uuidString,
            "text": todo.displayContent,
            "state": claudeTaskState(todo.state, workspaceWireFormat: true),
            "origin": "agent",
        ]
    }

    private func claudeTaskChecklistOwnerID(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity?
    ) -> String? {
        let namespace = taskStoreIdentity.map { "\($0.rawValue):" } ?? ""
        let ownerID = "claude:\(namespace)\(taskDirectoryName)"
        return ownerID.count <= 500 ? ownerID : nil
    }

    private func claudeTaskState(
        _ state: WorkstreamTaskTodo.State,
        workspaceWireFormat: Bool
    ) -> String {
        switch state {
        case .pending: return "pending"
        case .inProgress: return workspaceWireFormat ? "in-progress" : "in_progress"
        case .completed: return "completed"
        }
    }

    private func claudeTaskChecklistID(
        taskDirectoryName: String,
        taskStoreIdentity: ClaudeTaskStoreIdentity,
        taskID: String
    ) -> UUID {
        let name = "cmux.claude-task\0\(taskStoreIdentity.rawValue)\0\(taskDirectoryName)\0\(taskID)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
