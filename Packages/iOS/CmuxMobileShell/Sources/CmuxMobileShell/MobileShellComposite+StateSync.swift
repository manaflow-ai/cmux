import CMUXMobileCore
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
        stateSyncActive = false
        scheduleStateSyncFetch(client: client)
    }

    /// Handles one `mobile.sync.delta` event from the foreground event stream.
    /// The caller already proved the event belongs to the current client and a
    /// connected session.
    func handleStateSyncDeltaEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else {
            scheduleStateSyncRepairIfActive()
            return
        }
        guard let header = try? JSONDecoder().decode(MobileSyncDeltaEventHeader.self, from: payload) else {
            scheduleStateSyncRepairIfActive()
            return
        }
        let result: MobileSyncApplyResult
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
        case .groups:
            guard let delta = try? JSONDecoder().decode(
                MobileSyncDeltaEvent<GroupSyncRecord>.self, from: payload
            ) else {
                scheduleStateSyncRepairIfActive()
                return
            }
            result = stateSyncMirror.groups.apply(delta: delta)
        default:
            // A newer Mac may sync collections this build does not know; they
            // are simply not mirrored here.
            return
        }
        switch result {
        case .applied:
            applyStateSyncProjection()
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
    func performStateSyncFetch(client: MobileCoreRPCClient) async -> Bool {
        var task = scheduleStateSyncFetch(client: client)
        for _ in 0..<5 {
            let applied = await task.value
            if applied { return true }
            guard let replacement = stateSyncFetchTask, replacement != task else {
                return applied
            }
            task = replacement
        }
        return false
    }

    /// Repairs the mirror with a cursor fetch when the current client is v2.
    private func scheduleStateSyncRepairIfActive() {
        guard stateSyncActive, let client = remoteClient else { return }
        scheduleStateSyncFetch(client: client)
    }

    /// Single-flight, restart-on-newest cursor fetch (negotiation and gap
    /// repair share it, mirroring ``workspaceListRefreshTask`` semantics).
    @discardableResult
    private func scheduleStateSyncFetch(client: MobileCoreRPCClient) -> Task<Bool, Never> {
        stateSyncFetchTask?.cancel()
        let generation = UUID()
        stateSyncFetchGeneration = generation
        let task = Task { @MainActor [weak self] () -> Bool in
            defer {
                // Only the generation that still owns the handle may clear
                // it: a cancelled predecessor's deferred cleanup must not
                // erase the replacement's cancel handle.
                if let self, self.stateSyncFetchGeneration == generation {
                    self.stateSyncFetchTask = nil
                }
            }
            return await self?.runStateSyncFetch(client: client, generation: generation) ?? false
        }
        stateSyncFetchTask = task
        return task
    }

    @discardableResult
    private func runStateSyncFetch(
        client: MobileCoreRPCClient,
        generation: UUID
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
            params = try MobileSyncFrameJSON.jsonObject(from: stateSyncMirror.fetchRequest)
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
                timeoutNanoseconds: runtime?.rpcRequestTimeoutNanoseconds
            )
            guard remoteClient === client, connectionState == .connected, !Task.isCancelled else { return false }
            let response = try JSONDecoder().decode(MobileSyncFetchResponse.self, from: data)
            let result = stateSyncMirror.apply(response: response)
            stateSyncActive = true
            switch result {
            case .applied:
                applyStateSyncProjection()
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
                stateSyncActive = false
                return false
            }
            mobileStateSyncLog.error(
                "state sync fetch failed: \(String(describing: error), privacy: .private)"
            )
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
        guard stateSyncActive else { return }
        stateSyncActive = false
        Task { @MainActor [weak self] in
            // The missed delta may have been the last event, so this reload
            // cannot be fire-and-forget: retry a bounded number of times with
            // short pauses. If the connection itself is dead, the recovery
            // owner (stream-end/liveness paths) takes over and a successful
            // reconnect re-negotiates v2 with a snapshot anyway.
            for attempt in 0..<3 {
                guard let self, self.remoteClient === client,
                      self.connectionState == .connected,
                      !self.stateSyncActive else { return }
                if await self.reloadWorkspaceListFromMac() { return }
                try? await ContinuousClock().sleep(for: .seconds(2 << attempt))
            }
            mobileStateSyncLog.error("legacy fallback reload exhausted retries; awaiting next event or recovery")
        }
    }

    /// Projects the mirror into the legacy full-list response shape and hands
    /// it to the shared apply path. The mirror always holds full records, so
    /// the projection is always a complete, ordered list.
    private func applyStateSyncProjection() {
        let workspaces = stateSyncMirror.workspaces.orderedRecords.map { record in
            MobileSyncWorkspaceListResponse.Workspace(
                id: record.id,
                windowID: record.windowID,
                title: record.title,
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
            preferActiveTicketTarget: false
        )
        syncSelectedTerminalForWorkspace()
    }
}
