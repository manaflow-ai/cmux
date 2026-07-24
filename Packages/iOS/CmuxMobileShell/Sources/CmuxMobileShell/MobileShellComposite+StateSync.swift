import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileRPC
import Foundation
internal import OSLog

private let mobileStateSyncLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-state-sync"
)

// MARK: - Mobile state sync v2 (docs/mobile-state-sync-v2.md)
//
// Consumes `mobile.sync.delta` events and the `mobile.sync.fetch` cursor RPC,
// mirrors the Mac's workspace/group records locally, and projects the mirror
// into the exact `MobileSyncWorkspaceListResponse` shape the legacy full-list
// path applies, so everything downstream of `applyRemoteWorkspaceList` (per-Mac
// state, group collapse, selection sync) is shared, not duplicated. A Mac that
// does not implement `mobile.sync.fetch` answers `method_not_found` and this
// connection silently stays on the legacy refetch loop.
extension MobileShellComposite {
    /// Starts (or restarts) v2 negotiation for a freshly subscribed event
    /// stream. Runs concurrently with event consumption; a delta racing the
    /// fetch overlaps idempotently or gaps into a repair fetch.
    func beginStateSyncNegotiation(client: MobileCoreRPCClient) {
        stateSyncAuthorityClientID = nil
        scheduleStateSyncFetch(client: client)
    }

    /// Handles one `mobile.sync.delta` event from the foreground event stream.
    /// The caller already proved the event belongs to the current client and a
    /// connected session.
    func handleStateSyncDeltaEvent(_ event: MobileEventEnvelope) {
        // Deltas apply only while v2 is authoritative for the CURRENT client
        // (after a legacy fallback the list has a legacy writer, and mirror
        // projections must stop until renegotiation). During NEGOTIATION —
        // fetch runner in flight for this client — a delta may postdate the
        // fetch's snapshot, so it requests one trailing sweep instead of
        // being dropped or applied to a non-authoritative mirror.
        guard stateSyncActive else {
            if stateSyncFetchTask != nil, let client = remoteClient,
               stateSyncFetchClientID == ObjectIdentifier(client) {
                stateSyncFetchFollowUpRequested = true
            }
            return
        }
        guard let payload = event.payloadJSON else {
            scheduleStateSyncRepairIfActive()
            return
        }
        guard let header = try? JSONDecoder().decode(MobileSyncDeltaEventHeader.self, from: payload) else {
            scheduleStateSyncRepairIfActive()
            return
        }
        let result: MobileSyncApplyResult
        let changesSummaryRefreshScope: WorkspaceChangesSummaryRefreshScope
        let removedWorkspaceIDs: [String]
        switch header.collection {
        case .workspaces:
            guard let delta = try? JSONDecoder().decode(
                MobileSyncDeltaEvent<WorkspaceSyncRecord>.self, from: payload
            ) else {
                // A delta we KNOW is for a mirrored collection but cannot
                // decode is a lost update: without repair the mirror stays
                // silently stale until the next unrelated change gaps it.
                scheduleStateSyncRepairIfActive()
                return
            }
            result = stateSyncMirror.workspaces.apply(delta: delta)
            changesSummaryRefreshScope = .workspaceDelta(delta.records.map(\.id))
            removedWorkspaceIDs = delta.removedIDs
        case .groups:
            guard let delta = try? JSONDecoder().decode(
                MobileSyncDeltaEvent<GroupSyncRecord>.self, from: payload
            ) else {
                scheduleStateSyncRepairIfActive()
                return
            }
            result = stateSyncMirror.groups.apply(delta: delta)
            changesSummaryRefreshScope = .groupOnlyDelta
            removedWorkspaceIDs = []
        default:
            // A newer Mac may sync collections this build does not know; they
            // are simply not mirrored here.
            return
        }
        switch result {
        case .applied:
            evictWorkspaceChangesSummaryState(workspaceIDs: removedWorkspaceIDs)
            applyStateSyncProjection(
                changesSummaryRefreshScope: changesSummaryRefreshScope
            )
        case .staleIgnored:
            break
        case .gap:
            // Missed revisions (lost registration, dropped event). The cursor
            // fetch returns exactly the missing span, or a snapshot when the
            // span is no longer retained.
            if let client = remoteClient {
                scheduleStateSyncFetch(client: client)
            }
        }
    }

    /// Entry point for sibling composite extensions (liveness probe and
    /// event-driven repair paths): re-base the mirror through its cursor.
    func requestStateSyncFetch(client: MobileCoreRPCClient) {
        scheduleStateSyncFetch(client: client)
    }


    /// Awaitable variant for user-visible refresh gestures: the spinner must
    /// not end before the authoritative fetch applied (or failed). The
    /// single-flight slot is cancel-and-replace, so a delta-driven repair can
    /// supersede this gesture's task mid-flight; in that case the replacement
    /// is the authoritative fetch and the gesture follows it (bounded) rather
    /// than reporting a superseded cancel as failure.
    func performStateSyncFetch(
        client: MobileCoreRPCClient,
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        // Single-flight: same-client demand coalesces onto the in-flight
        // runner, so awaiting the returned task IS awaiting the authoritative
        // outcome (a trailing follow-up sweep runs inside the same task). The
        // runner is cancelled only on client change or account teardown, where
        // false is the correct answer for this client's gesture.
        //
        // Each WAITER is bounded by its own deadline: a 3s liveness probe
        // joining a slow 30s fetch must report within its contract, not the
        // runner's. The runner itself is never cancelled by a waiter's
        // deadline; it keeps converging in the background.
        let task = scheduleStateSyncFetch(client: client, timeoutNanoseconds: timeoutNanoseconds)
        guard let timeoutNanoseconds else {
            return await task.value
        }
        let race = await Self.raceAgainstDeadline(nanoseconds: timeoutNanoseconds) {
            await task.value
        }
        return race.value ?? false
    }

    /// Account-boundary teardown: wipes mirrored records (titles,
    /// directories, notification previews from the previous account's Macs),
    /// deactivates v2, and invalidates any in-flight fetch so its completion
    /// cannot write into the next account's session.
    func resetStateSyncForAccountBoundary() {
        stateSyncFetchTask?.cancel()
        stateSyncFetchTask = nil
        stateSyncFetchGeneration = UUID()
        stateSyncAuthorityClientID = nil
        stateSyncFetchClientID = nil
        stateSyncFetchFollowUpRequested = false
        stateSyncMirror.reset()
    }

    /// Repairs the mirror with a cursor fetch when the current client is v2.
    private func scheduleStateSyncRepairIfActive() {
        guard stateSyncActive, let client = remoteClient else { return }
        scheduleStateSyncFetch(client: client)
    }

    /// Single-flight, restart-on-newest cursor fetch (negotiation and gap
    /// repair share it, mirroring ``workspaceListRefreshTask`` semantics).
    @discardableResult
    private func scheduleStateSyncFetch(
        client: MobileCoreRPCClient,
        timeoutNanoseconds: UInt64? = nil
    ) -> Task<Bool, Never> {
        // Single-flight per client: new demand while a runner is in flight
        // requests one trailing sweep and attaches to the runner. Cancelling
        // in-flight repairs on every demand starves convergence under
        // sustained 80ms churn (each gap-path delta would kill the repair it
        // needs); only a DIFFERENT client's demand replaces the runner.
        if let running = stateSyncFetchTask,
           stateSyncFetchClientID == ObjectIdentifier(client) {
            stateSyncFetchFollowUpRequested = true
            return running
        }
        stateSyncFetchTask?.cancel()
        let generation = UUID()
        stateSyncFetchGeneration = generation
        stateSyncFetchClientID = ObjectIdentifier(client)
        stateSyncFetchFollowUpRequested = false
        let task = Task { @MainActor [weak self] () -> Bool in
            var applied = false
            while true {
                guard let self, !Task.isCancelled,
                      self.stateSyncFetchGeneration == generation else { return applied }
                self.stateSyncFetchFollowUpRequested = false
                applied = await self.runStateSyncFetch(
                    client: client,
                    generation: generation,
                    timeoutNanoseconds: timeoutNanoseconds
                )
                // One trailing sweep per follow-up request; a failed fetch
                // does not loop (the fallback path owns failure recovery).
                guard applied, self.stateSyncFetchGeneration == generation,
                      self.stateSyncFetchFollowUpRequested, !Task.isCancelled else { break }
            }
            if let self, self.stateSyncFetchGeneration == generation {
                self.stateSyncFetchTask = nil
                self.stateSyncFetchClientID = nil
            }
            return applied
        }
        stateSyncFetchTask = task
        return task
    }

    @discardableResult
    private func runStateSyncFetch(
        client: MobileCoreRPCClient,
        generation: UUID,
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        // Currency check BEFORE the send, not only after: a negotiation task
        // scheduled for a listener generation that has since been replaced
        // must not touch its stale client at all — `sendRequest` on a
        // torn-down session would redial that client's route underneath the
        // replacement connection (an extra transport dial the reconnect
        // paths never asked for).
        guard remoteClient === client, connectionState == .connected, !Task.isCancelled else { return false }
        let params: [String: Any]
        do {
            params = try MobileSyncFrameCoder().jsonObject(from: stateSyncMirror.fetchRequest)
        } catch {
            return false
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.sync.fetch",
                params: params
            )
            let data = try await client.sendRequest(
                request,
                timeoutNanoseconds: timeoutNanoseconds ?? runtime?.rpcRequestTimeoutNanoseconds
            )
            guard remoteClient === client, connectionState == .connected, !Task.isCancelled else { return false }
            let response = try JSONDecoder().decode(MobileSyncFetchResponse.self, from: data)
            // The response shape tolerates missing sections for forward
            // compatibility, but v2 must never become authoritative on a
            // partial answer: projecting an empty workspace mirror would
            // clear a valid list. Both requested collections must be present.
            guard response.workspaces != nil, response.groups != nil else {
                guard !Task.isCancelled, stateSyncFetchGeneration == generation else { return false }
                mobileStateSyncLog.error("state sync fetch returned a partial response; staying on legacy")
                fallBackToLegacyListAfterFetchFailure(client: client)
                return false
            }
            let result = stateSyncMirror.apply(response: response)
            stateSyncAuthorityClientID = ObjectIdentifier(client)
            switch result {
            case .applied:
                evictWorkspaceChangesSummaryState(
                    workspaceIDs: response.workspaces?.removedIDs ?? []
                )
                let changesSummaryRefreshScope: WorkspaceChangesSummaryRefreshScope =
                    response.workspaces?.mode == .snapshot
                        ? .fullSnapshot
                        : .workspaceDelta(response.workspaces?.records.map(\.id) ?? [])
                applyStateSyncProjection(
                    changesSummaryRefreshScope: changesSummaryRefreshScope
                )
            case .staleIgnored:
                break
            case .gap:
                // A fetch section can only gap if the store moved between
                // building the response's sections; one repair round covers it.
                scheduleStateSyncFetch(client: client)
            }
            return true
        } catch {
            // Failure handling belongs to the OWNING generation only: a
            // cancelled predecessor's send can surface as a timeout after its
            // replacement already succeeded, and acting on it would disable
            // v2 underneath authoritative state.
            guard !Task.isCancelled, stateSyncFetchGeneration == generation else { return false }
            if case MobileShellConnectionError.rpcError(let code, _) = error, code == "method_not_found" {
                // Legacy Mac: stay on the workspace.updated refetch loop for
                // this connection. Not an error.
                stateSyncAuthorityClientID = nil
                return false
            }
            mobileStateSyncLog.error(
                "state sync fetch failed: \(String(describing: error), privacy: .private)"
            )
            MobileDebugLog.anchormux("sync.v2 fetch failed; falling back")
            fallBackToLegacyListAfterFetchFailure(client: client)
            return false
        }
    }

    /// A failed repair fetch must not strand the mirror: while
    /// ``stateSyncActive`` suppresses the `workspace.updated` refetch loop,
    /// the missed delta may have been the last event, so with no fallback the
    /// list could stay stale indefinitely. Drop back to legacy semantics (the
    /// availability floor) and converge with one authoritative reload; the
    /// next event-listener generation re-negotiates v2.
    private func fallBackToLegacyListAfterFetchFailure(client: MobileCoreRPCClient) {
        guard remoteClient === client, connectionState == .connected else { return }
        // Unconditional on transient failure: during renegotiation the
        // authority was already cleared before the fetch, and events missed
        // in the subscription gap still need the authoritative reload — a
        // guard on current authority here would skip exactly the recovery
        // this exists for.
        stateSyncAuthorityClientID = nil
        MobileDebugLog.anchormux("sync.v2 fallback to legacy after fetch failure")
        Task { @MainActor [weak self] in
            // The missed delta may have been the last event, so this reload
            // cannot be fire-and-forget: retry a bounded number of times with
            // short pauses. If the connection itself is dead, the recovery
            // owner (stream-end/liveness paths) takes over and a successful
            // reconnect re-negotiates v2 with a snapshot anyway.
            for attempt in 0..<3 {
                guard let self, self.remoteClient === client,
                      self.connectionState == .connected,
                      !self.stateSyncActive else {
                    MobileDebugLog.anchormux("sync.v2 fallback loop guard exited")
                    return
                }
                MobileDebugLog.anchormux("sync.v2 fallback reload attempt \(attempt)")
                if await self.reloadWorkspaceListFromMac() { return }
                try? await ContinuousClock().sleep(for: .seconds(2 << attempt))
            }
            mobileStateSyncLog.error("legacy fallback reload exhausted retries; awaiting next event or recovery")
        }
    }

    /// Projects the mirror into the legacy full-list response shape and hands
    /// it to the shared apply path. The mirror always holds full records, so
    /// the projection is always a complete, ordered list.
    private func applyStateSyncProjection(
        changesSummaryRefreshScope: WorkspaceChangesSummaryRefreshScope
    ) {
        let workspaces = stateSyncMirror.workspaces.orderedRecords.map { record in
            MobileSyncWorkspaceListResponse.Workspace(
                id: record.id,
                windowID: record.windowID,
                title: record.title,
                customDescription: record.customDescription,
                customDescriptionIsTruncated: record.customDescriptionIsTruncated,
                customColorHex: record.customColorHex,
                currentDirectory: record.currentDirectory,
                isSelected: record.isSelected,
                isPinned: record.isPinned,
                groupID: record.groupID,
                preview: record.preview,
                previewAt: record.previewAt,
                lastActivityAt: record.lastActivityAt,
                hasUnread: record.hasUnread,
                terminals: record.terminals.map { terminal in
                    MobileSyncWorkspaceListResponse.Terminal(
                        id: terminal.id,
                        title: terminal.title,
                        currentDirectory: terminal.currentDirectory,
                        isFocused: terminal.isFocused,
                        isReady: terminal.isReady
                    )
                }
            )
        }
        let groups = stateSyncMirror.groups.orderedRecords.map { record in
            MobileSyncWorkspaceListResponse.Group(
                id: record.id,
                name: record.name,
                isCollapsed: record.isCollapsed,
                isPinned: record.isPinned,
                anchorWorkspaceID: record.anchorWorkspaceID
            )
        }
        applyRemoteWorkspaceList(
            MobileSyncWorkspaceListResponse(
                workspaces: workspaces,
                groups: groups,
                createdWorkspaceID: nil,
                createdTerminalID: nil
            ),
            preferActiveTicketTarget: false,
            changesSummaryRefreshScope: changesSummaryRefreshScope
        )
        syncSelectedTerminalForWorkspace()
    }
}
