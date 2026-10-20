import Foundation
import AppKit
import CmuxFoundation

extension AppDelegate {
    func startOpenDiffViewerAgentContextTask(
        _ request: OpenDiffViewerAgentContextRequest,
        taskKey: String
    ) {
        openDiffViewerAgentContextTasks[taskKey] = Task.detached(priority: .userInitiated) {
            let repoRoot = Self.latestAgentTurnDiffRepoRoot(
                storeURL: request.storeURL,
                workspaceId: request.workspaceId,
                surfaceId: request.surfaceId,
                sessionId: request.sessionId
            )
            await MainActor.run {
                AppDelegate.shared?.finishOpenDiffViewerAgentContextTask(
                    request,
                    taskKey: taskKey,
                    repoRoot: repoRoot
                )
            }
        }
    }

    func finishOpenDiffViewerAgentContextTask(
        _ request: OpenDiffViewerAgentContextRequest,
        taskKey: String,
        repoRoot: String?
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
        let cwd = repoRoot ?? request.snapshotWorkingDirectory ?? request.fallbackCwd
        let useLastTurnSource = repoRoot != nil
        guard launchDiffViewerProcess(
            cliURL: request.cliURL,
            socketPath: request.socketPath,
            cwd: cwd,
            workspaceId: request.workspaceId,
            surfaceId: request.surfaceId,
            useLastTurnSource: useLastTurnSource,
            sessionId: request.sessionId,
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
        return candidates.max(by: { $0.capturedAt < $1.capturedAt })?.repoRoot
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

    nonisolated static func agentTurnDiffBaselineStoreURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = normalizedOpenDiffViewerPath(environment["CMUX_AGENT_HOOK_STATE_DIR"]) {
            let expandedOverride = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedOverride, isDirectory: true)
                .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false)
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
