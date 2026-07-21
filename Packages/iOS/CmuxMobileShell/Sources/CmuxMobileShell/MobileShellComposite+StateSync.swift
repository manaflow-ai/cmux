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
    /// pull-to-refresh paths): re-base the mirror through its cursor.
    func requestStateSyncFetch(client: MobileCoreRPCClient) {
        scheduleStateSyncFetch(client: client)
    }

    /// Repairs the mirror with a cursor fetch when the current client is v2.
    private func scheduleStateSyncRepairIfActive() {
        guard stateSyncActive, let client = remoteClient else { return }
        scheduleStateSyncFetch(client: client)
    }

    /// Single-flight, restart-on-newest cursor fetch (negotiation and gap
    /// repair share it, mirroring ``workspaceListRefreshTask`` semantics).
    private func scheduleStateSyncFetch(client: MobileCoreRPCClient) {
        stateSyncFetchTask?.cancel()
        let generation = UUID()
        stateSyncFetchGeneration = generation
        stateSyncFetchTask = Task { @MainActor [weak self] in
            defer {
                // Only the generation that still owns the handle may clear
                // it: a cancelled predecessor's deferred cleanup must not
                // erase the replacement's cancel handle.
                if let self, self.stateSyncFetchGeneration == generation {
                    self.stateSyncFetchTask = nil
                }
            }
            await self?.runStateSyncFetch(client: client)
        }
    }

    private func runStateSyncFetch(client: MobileCoreRPCClient) async {
        // Currency check BEFORE the send, not only after: a negotiation task
        // scheduled for a listener generation that has since been replaced
        // must not touch its stale client at all — `sendRequest` on a
        // torn-down session would redial that client's route underneath the
        // replacement connection (an extra transport dial the reconnect
        // paths never asked for).
        guard remoteClient === client, connectionState == .connected, !Task.isCancelled else { return }
        let params: [String: Any]
        do {
            params = try MobileSyncFrameJSON.jsonObject(from: stateSyncMirror.fetchRequest)
        } catch {
            return
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
            guard remoteClient === client, connectionState == .connected, !Task.isCancelled else { return }
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
        } catch let error as MobileShellConnectionError {
            if case .rpcError(let code, _) = error, code == "method_not_found" {
                // Legacy Mac: stay on the workspace.updated refetch loop for
                // this connection. Not an error.
                stateSyncActive = false
                return
            }
            mobileStateSyncLog.error(
                "state sync fetch failed: \(String(describing: error), privacy: .private)"
            )
        } catch {
            mobileStateSyncLog.error(
                "state sync fetch failed: \(String(describing: error), privacy: .private)"
            )
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
