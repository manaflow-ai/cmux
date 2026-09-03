import Foundation
import CmuxNestedTopology

@MainActor
extension RemoteHerdrController {
    /// Attach every discovered Herdr workspace (or a filtered set) into cmux tabs.
    @discardableResult
    func attachHost(
        socketPath: String,
        windowTarget: RemoteHerdrAttachWindowTarget,
        activate: Bool,
        sessionFilter: String? = nil
    ) async throws -> [String: Any] {
        guard Self.isEnabled else { throw RemoteHerdrHostError.disabled }
        guard let path = RemoteHerdrLifecycle.validateSocketPath(socketPath) else {
            throw RemoteHerdrHostError.invalidParams
        }
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteHerdrHostError.unreachable("app not ready")
        }

        let endpointHash = RemoteHerdrLifecycle.endpointHash(path)
        let initialExistingMirrorWindowID = existingMirrorManager(endpointHash: endpointHash)
            .flatMap { appDelegate.windowId(for: $0)?.uuidString }
        let initialActiveWindowID = appDelegate.tabManager
            .flatMap { appDelegate.windowId(for: $0)?.uuidString }

        let preflight = RemoteHerdrAttachPlanner.plan(
            target: windowTarget,
            enabled: Self.isEnabled,
            appReady: true,
            alreadyAttaching: isAttaching(endpointHash: endpointHash),
            existingMirrorWindowID: initialExistingMirrorWindowID,
            activeWindowID: initialActiveWindowID,
            liveWindows: liveWindowIDs(appDelegate),
            sessions: nil
        )
        if preflight.outcome == "already_attaching" {
            throw RemoteHerdrHostError.alreadyAttaching
        }
        if preflight.outcome == "invalid_target" {
            throw RemoteHerdrHostError.unreachable("app not ready")
        }

        guard beginAttach(endpointHash: endpointHash) else {
            throw RemoteHerdrHostError.alreadyAttaching
        }
        defer { endAttach(endpointHash: endpointHash) }

        let sessions = try await listSessions(socketPath: path)
        let filtered: [RemoteHerdrDiscoveredSession]
        if let sessionFilter,
           let name = RemoteHerdrLifecycle.validateSessionName(sessionFilter) {
            filtered = sessions.filter { $0.sessionID == name || $0.name == name }
        } else {
            filtered = sessions
        }
        guard !filtered.isEmpty else { throw RemoteHerdrHostError.noSessions }
        try Task.checkCancellation()

        let liveWindows = liveWindowIDs(appDelegate)
        let mirrors = mirrorRecords(endpointHash: endpointHash, appDelegate: appDelegate)
        let liveSessionIDs = mirrors.compactMap { record -> String? in
            record.workspaceID != nil ? record.sessionID : nil
        }
        let plan = RemoteHerdrAttachPlanner.plan(
            target: windowTarget,
            enabled: Self.isEnabled,
            appReady: true,
            alreadyAttaching: false,
            existingMirrorWindowID: initialExistingMirrorWindowID,
            activeWindowID: initialActiveWindowID,
            liveWindows: liveWindows,
            sessions: filtered,
            mirrors: mirrors,
            liveSessionIDs: liveSessionIDs,
            activate: activate
        )
        if plan.outcome == "disabled" || plan.outcome == "no_sessions" {
            throw RemoteHerdrHostError.noSessions
        }

        purgeDeadHosts(endpointHash: endpointHash)

        let resolvedWindowId: UUID
        let targetManager: TabManager
        let bootstrapWorkspaceId: UUID?
        if plan.createWindow {
            resolvedWindowId = appDelegate.createMainWindow(shouldActivate: false)
            guard let newWindowManager = appDelegate.tabManagerFor(windowId: resolvedWindowId) else {
                appDelegate.discardMainWindowWithoutClosedHistory(windowId: resolvedWindowId)
                throw RemoteHerdrHostError.windowCreationFailed
            }
            targetManager = newWindowManager
            bootstrapWorkspaceId = newWindowManager.tabs.first?.id
            moveExistingMirrors(endpointHash: endpointHash, into: targetManager)
        } else {
            guard let windowIDString = plan.windowID,
                  let windowUUID = UUID(uuidString: windowIDString),
                  let existingWindowManager = appDelegate.tabManagerFor(windowId: windowUUID)
            else {
                throw RemoteHerdrHostError.unreachable("app not ready")
            }
            resolvedWindowId = windowUUID
            targetManager = existingWindowManager
            bootstrapWorkspaceId = nil
        }

        var workspaceIds: [UUID] = []
        var sessionFailures: [[String: Any]] = []
        let sessionsToCreate = plan.sessionsToMirror.isEmpty
            ? filtered.map(\.sessionID)
            : plan.sessionsToMirror
        for sessionID in sessionsToCreate {
            try Task.checkCancellation()
            let session = filtered.first { $0.sessionID == sessionID }
            do {
                if let workspaceId = try await mirrorSession(
                    socketPath: path,
                    sessionID: sessionID,
                    sessionName: session?.name ?? sessionID,
                    into: targetManager
                ) {
                    workspaceIds.append(workspaceId)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.warning("remote-herdr: mirror session failed session=\(sessionID, privacy: .public)")
                sessionFailures.append([
                    "session_id": sessionID,
                    "error_code": RemoteHerdrHostError.publicCode(for: error),
                    "error": RemoteHerdrHostError.publicMessage(for: error),
                ])
            }
        }
        try Task.checkCancellation()
        for sessionID in plan.sessionsToReuse {
            if let host = sessionHosts[Self.connectionKey(endpointHash: endpointHash, sessionID: sessionID)],
               let workspaceId = host.mirroredWorkspaceId {
                workspaceIds.append(workspaceId)
                if plan.postAttach == RemoteHerdrLifecycle.postReseed {
                    host.requestReseed()
                }
            }
        }
        try Task.checkCancellation()

        guard !workspaceIds.isEmpty else {
            if plan.discardWindowOnFail {
                appDelegate.discardMainWindowWithoutClosedHistory(windowId: resolvedWindowId)
            }
            throw RemoteHerdrHostError.mirrorFailed
        }

        if let bootstrapWorkspaceId,
           targetManager.tabs.count > 1,
           let bootstrap = targetManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           !bootstrap.isRemoteHerdrMirror {
            targetManager.closeWorkspace(bootstrap, recordHistory: false)
        }

        if activate {
            if let first = workspaceIds.first,
               let workspace = targetManager.tabs.first(where: { $0.id == first }) {
                targetManager.selectWorkspace(workspace)
            }
            _ = appDelegate.focusMainWindow(windowId: resolvedWindowId)
        }

        return [
            "ok": true,
            "outcome": plan.outcome,
            "socket": path,
            "mirrored": true,
            "window_id": resolvedWindowId.uuidString,
            "workspace_ids": workspaceIds.map(\.uuidString),
            "session_failures": sessionFailures,
            "post_attach": plan.postAttach as Any,
            "server_stopped": false,
        ]
    }

    /// Creates one session host + workspace for a Herdr workspace id.
    @discardableResult
    func mirrorSession(
        socketPath: String,
        sessionID: String,
        sessionName: String,
        into tabManager: TabManager
    ) async throws -> UUID? {
        let endpointHash = RemoteHerdrLifecycle.endpointHash(socketPath)
        let key = Self.connectionKey(endpointHash: endpointHash, sessionID: sessionID)
        if let existing = sessionHosts[key], let workspaceId = existing.mirroredWorkspaceId {
            return workspaceId
        }

        let attachmentID = UUID()
        let hostStableSurfaceID = UUID()
        let client = HerdrNestedTopologyClient(
            configuration: HerdrNestedTopologyClientConfiguration(
                socketPath: socketPath,
                attachmentID: attachmentID,
                hostStableSurfaceID: hostStableSurfaceID
            )
        )
        _ = try await client.handshake()
        let (snapshot, layouts) = try await client.snapshotWithLayouts()

        let workspace = tabManager.addWorkspace(
            title: sessionName,
            titleSource: .auto,
            select: false,
            autoWelcomeIfNeeded: false,
            applyCreationTitleAsCustomTitle: false
        )
        workspace.isRemoteHerdrMirror = true

        let host = RemoteHerdrSessionHost(
            socketPath: socketPath,
            sessionID: sessionID,
            sessionName: sessionName,
            client: client,
            attachmentID: attachmentID,
            hostStableSurfaceID: hostStableSurfaceID,
            tabManager: tabManager,
            workspace: workspace
        )
        do {
            try await host.applyInitialSnapshot(snapshot, layouts: layouts)
            try register(host, key: key)
            return workspace.id
        } catch {
            host.detach(reason: "register_failed")
            tabManager.closeWorkspace(workspace, recordHistory: false)
            throw error
        }
    }

    private func liveWindowIDs(_ appDelegate: AppDelegate) -> [String] {
        var ids: [String] = []
        var seen: Set<String> = []
        func insert(_ id: UUID?) {
            guard let id else { return }
            let text = id.uuidString
            if seen.insert(text).inserted {
                ids.append(text)
            }
        }
        if let active = appDelegate.tabManager {
            insert(appDelegate.windowId(for: active))
        }
        for host in sessionHosts.values {
            guard let workspaceId = host.mirroredWorkspaceId,
                  let manager = appDelegate.tabManagerFor(tabId: workspaceId)
            else { continue }
            insert(appDelegate.windowId(for: manager))
        }
        return ids
    }

    private func mirrorRecords(endpointHash: String, appDelegate: AppDelegate) -> [RemoteHerdrMirrorRecord] {
        sessionHosts.compactMap { key, host -> RemoteHerdrMirrorRecord? in
            guard key.hasPrefix(endpointHash) else { return nil }
            let windowID = host.mirroredWorkspace
                .flatMap { $0.owningTabManager ?? appDelegate.tabManagerFor(tabId: $0.id) }
                .flatMap { appDelegate.windowId(for: $0)?.uuidString }
                ?? ""
            return RemoteHerdrMirrorRecord(
                sessionID: host.sessionID,
                windowID: windowID,
                workspaceID: host.mirroredWorkspaceId?.uuidString
            )
        }
    }

    private func moveExistingMirrors(endpointHash: String, into targetManager: TabManager) {
        let hostWorkspaceIds = Set(sessionHosts.values.compactMap { host -> UUID? in
            guard RemoteHerdrLifecycle.endpointHash(host.socketPath) == endpointHash else { return nil }
            return host.mirroredWorkspaceId
        })
        var sourceManagers: [TabManager] = []
        var seen: Set<ObjectIdentifier> = []
        for host in sessionHosts.values
        where RemoteHerdrLifecycle.endpointHash(host.socketPath) == endpointHash {
            guard let workspaceId = host.mirroredWorkspaceId,
                  let source = host.mirroredWorkspace?.owningTabManager
                    ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  source !== targetManager,
                  seen.insert(ObjectIdentifier(source)).inserted
            else { continue }
            sourceManagers.append(source)
        }
        for source in sourceManagers {
            let workspaces = source.tabs.filter { hostWorkspaceIds.contains($0.id) }
            for workspace in workspaces {
                guard let detached = source.detachWorkspace(tabId: workspace.id) else { continue }
                targetManager.attachWorkspace(detached, select: false)
            }
        }
    }
}
