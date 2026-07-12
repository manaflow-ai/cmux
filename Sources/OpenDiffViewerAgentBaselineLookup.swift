import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import Foundation

nonisolated struct OpenDiffViewerAgentBaselineContext: Sendable, Equatable {
    let repoRoot: String
    let storeURL: URL
}

extension AppDelegate {
    func startOpenDiffViewerAgentContextTask(
        _ request: OpenDiffViewerAgentContextRequest,
        taskKey: String
    ) {
        openDiffViewerAgentContextTasks[taskKey] = Task.detached(priority: .userInitiated) {
            let baselineContext = Self.latestAgentTurnDiffContext(
                storeURLs: request.storeURLs,
                workspaceId: request.workspaceId,
                surfaceId: request.surfaceId,
                sessionId: request.sessionId
            )
            await MainActor.run {
                AppDelegate.shared?.finishOpenDiffViewerAgentContextTask(
                    request,
                    taskKey: taskKey,
                    baselineContext: baselineContext
                )
            }
        }
    }

    func finishOpenDiffViewerAgentContextTask(
        _ request: OpenDiffViewerAgentContextRequest,
        taskKey: String,
        baselineContext: OpenDiffViewerAgentBaselineContext?
    ) {
        openDiffViewerAgentContextTasks.removeValue(forKey: taskKey)
        let pendingRequest = openDiffViewerAgentContextPendingRequests.removeValue(forKey: taskKey)
        if let pendingRequest {
            startOpenDiffViewerAgentContextTask(pendingRequest, taskKey: taskKey)
            return
        }
        guard let shouldFocus = openDiffViewerAgentContextShouldFocus(
            workspaceId: request.workspaceId,
            surfaceId: request.surfaceId,
            sessionId: request.sessionId,
            originWindowId: request.originWindowId
        ) else {
            return
        }
        let cwd = baselineContext?.repoRoot ?? request.snapshotWorkingDirectory ?? request.fallbackCwd
        let useLastTurnSource = baselineContext != nil
        guard launchDiffViewerProcess(
            cliURL: request.cliURL,
            socketPath: request.socketPath,
            cwd: cwd,
            workspaceId: request.workspaceId,
            surfaceId: request.surfaceId,
            useLastTurnSource: useLastTurnSource,
            sessionId: request.sessionId,
            baselineStoreURL: baselineContext?.storeURL,
            focus: shouldFocus
        ) == true else {
            NSSound.beep()
            return
        }
    }

    /// Returns nil when no matching context exists, false when focus moved, and true when it remains focused.
    func openDiffViewerAgentContextShouldFocus(
        workspaceId: UUID,
        surfaceId: UUID,
        sessionId: String,
        originWindowId: UUID?
    ) -> Bool? {
        for context in mainWindowContexts.values {
            guard let workspace = context.tabManager.tabs.first(where: {
                $0.id == workspaceId && $0.panels.keys.contains(surfaceId)
            }),
                  let snapshot = SharedLiveAgentIndex.shared.snapshot(workspaceId: workspaceId, panelId: surfaceId),
                  Self.normalizedOpenDiffViewerSessionId(snapshot.sessionId) == sessionId else {
                continue
            }
            guard let originWindowId,
                  context.windowId == originWindowId,
                  NSApp.isActive,
                  (context.window?.isKeyWindow == true || context.window?.isMainWindow == true) else {
                return false
            }
            return context.tabManager.selectedWorkspace?.id == workspaceId &&
                workspace.focusedPanelId == surfaceId
        }
        return nil
    }

    nonisolated static func latestAgentTurnDiffRepoRoot(
        storeURL: URL,
        workspaceId: UUID,
        surfaceId: UUID,
        sessionId: String
    ) -> String? {
        latestAgentTurnDiffCandidate(
            storeURL: storeURL,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: sessionId
        )?.repoRoot
    }

    nonisolated static func latestAgentTurnDiffCandidate(
        storeURL: URL,
        workspaceId: UUID,
        surfaceId: UUID,
        sessionId: String
    ) -> (repoRoot: String, capturedAt: TimeInterval)? {
        guard let data = try? Data(contentsOf: storeURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]] else {
            return nil
        }
        let workspaceKey = workspaceId.uuidString.lowercased()
        let surfaceKey = surfaceId.uuidString.lowercased()
        let candidates = records.compactMap { record -> (repoRoot: String, capturedAt: TimeInterval)? in
            guard let recordWorkspace = normalizedOpenDiffViewerIdentifier(record["workspaceId"] as? String),
                  let recordSurface = normalizedOpenDiffViewerIdentifier(record["surfaceId"] as? String),
                  let recordSession = normalizedOpenDiffViewerSessionId(record["sessionId"] as? String),
                  recordWorkspace == workspaceKey,
                  recordSurface == surfaceKey,
                  recordSession == sessionId,
                  let repoRoot = normalizedOpenDiffViewerPath(record["repoRoot"] as? String) else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: repoRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            let capturedAt = (record["capturedAt"] as? NSNumber)?.doubleValue ?? 0
            return (repoRoot, capturedAt)
        }
        return candidates.max(by: { $0.capturedAt < $1.capturedAt })
    }

    nonisolated static func latestAgentTurnDiffContext(
        storeURLs: [URL],
        workspaceId: UUID,
        surfaceId: UUID,
        sessionId: String
    ) -> OpenDiffViewerAgentBaselineContext? {
        var best: (context: OpenDiffViewerAgentBaselineContext, capturedAt: TimeInterval)?
        for storeURL in storeURLs {
            guard let candidate = latestAgentTurnDiffCandidate(
                storeURL: storeURL,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                sessionId: sessionId
            ) else {
                continue
            }
            if let best, candidate.capturedAt <= best.capturedAt {
                continue
            }
            best = (
                OpenDiffViewerAgentBaselineContext(repoRoot: candidate.repoRoot, storeURL: storeURL),
                candidate.capturedAt
            )
        }
        return best?.context
    }

    nonisolated static func openDiffViewerAgentContextTaskKey(
        workspaceId: UUID,
        surfaceId: UUID,
        sessionId: String
    ) -> String {
        [
            workspaceId.uuidString.lowercased(),
            surfaceId.uuidString.lowercased(),
            sessionId
        ].joined(separator: ":")
    }

    nonisolated static func agentTurnDiffBaselineStoreURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        legacyHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        AgentHookStateReaderLocation(
            environment: environment,
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: bundleIdentifier,
            legacyHomeDirectory: legacyHomeDirectory,
            fileManager: .default
        ).compatibilityFileURLs(named: "agent-turn-diff-baselines.json")
    }

    nonisolated static func diffViewerProcessEnvironment(
        baseEnvironment: [String: String],
        socketPath: String,
        cliURL: URL,
        workspaceId: UUID,
        surfaceId: UUID?,
        baselineStoreURL: URL?
    ) -> [String: String] {
        var environment = baseEnvironment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment["CMUX_WORKSPACE_ID"] = workspaceId.uuidString
        if let surfaceId {
            environment["CMUX_SURFACE_ID"] = surfaceId.uuidString
        } else {
            environment.removeValue(forKey: "CMUX_SURFACE_ID")
        }
        if let baselineStoreURL {
            environment["CMUX_AGENT_HOOK_STATE_DIR"] = baselineStoreURL.deletingLastPathComponent().path
        } else {
            environment.removeValue(forKey: "CMUX_AGENT_HOOK_STATE_DIR")
        }
        environment.removeValue(forKey: "CMUX_SOCKET")
        return environment
    }

    nonisolated static func normalizedOpenDiffViewerIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    nonisolated static func normalizedOpenDiffViewerSessionId(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    nonisolated static func normalizedOpenDiffViewerPath(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}
