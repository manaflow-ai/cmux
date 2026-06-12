import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - codex-teams app-server watcher
extension CMUXCLI {
    static let codexTeamsMaxAutoDepth = 2
    private static let codexTeamsReconcileInterval: TimeInterval = 1
    private static let codexTeamsMaxCachedApprovalItems = 500
    private static let codexTeamsApprovalMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval"
    ]
    static let codexTeamsProbeClientName = "codex_app_server_daemon"
    private static let codexTeamsWatcherClientName = "cmux-codex-teams"
    static let codexTeamsClientVersion = "0.1.0"
    private static let codexTeamsWatcherResumeOptOutNotificationMethods = [
        "thread/tokenUsage/updated",
        "turn/diff/updated",
        "turn/plan/updated",
        "item/agentMessage/delta",
        "item/plan/delta",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/textDelta",
        "command/exec/outputDelta",
        "process/outputDelta",
        "item/fileChange/outputDelta",
        "item/mcpToolCall/progress",
        "thread/turn/delta",
        "turn/delta",
        "item/textDelta",
        "item/thinkingDelta",
        "item/reasoningDelta",
        "item/commandExecution/outputDelta",
        "item/commandExecution/stdoutDelta",
        "item/commandExecution/stderrDelta",
        "item/outputDelta"
    ]

    struct CodexTeamsSpawn {
        let parentThreadId: String
        let sourceDepth: Int?
        let agentNickname: String?
        let agentRole: String?
    }

    struct CodexTeamsThread {
        let id: String
        let cwd: String?
        let statusType: String?
        let agentNickname: String?
        let agentRole: String?
        let spawn: CodexTeamsSpawn?
    }

    final class CodexTeamsAsyncBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?

        func set(_ value: Value) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        func take() -> Value? {
            lock.lock()
            defer { lock.unlock() }
            let value = stored
            stored = nil
            return value
        }
    }

    final class CodexTeamsAppServerConnection {
        private let session: URLSession
        private let task: URLSessionWebSocketTask
        private var nextRequestId = 1

        init(url: URL) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            session = URLSession(configuration: configuration)
            task = session.webSocketTask(with: url)
        }

        func resume() {
            task.resume()
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        func initialize(
            clientName: String,
            version: String,
            optOutNotificationMethods: [String] = [],
            responseTimeout: TimeInterval = 10
        ) throws {
            var capabilities: [String: Any] = [
                "experimentalApi": true
            ]
            if !optOutNotificationMethods.isEmpty {
                capabilities["optOutNotificationMethods"] = optOutNotificationMethods
            }
            _ = try request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": clientName,
                        "title": "cmux Codex Teams",
                        "version": version
                    ],
                    "capabilities": capabilities
                ],
                notificationHandler: nil,
                responseTimeout: responseTimeout
            )
            try sendObject(["method": "initialized"], timeout: responseTimeout)
        }

        func respond(requestId: Any, result: [String: Any], timeout: TimeInterval = 10) throws {
            try sendObject([
                "id": requestId,
                "result": result
            ], timeout: timeout)
        }

        func request(
            method: String,
            params: [String: Any]? = nil,
            notificationHandler: (([String: Any]) throws -> Void)? = nil,
            responseTimeout: TimeInterval = 10
        ) throws -> [String: Any] {
            let requestId = nextRequestId
            nextRequestId += 1
            var object: [String: Any] = [
                "id": requestId,
                "method": method
            ]
            if let params {
                object["params"] = params
            }
            try sendObject(object, timeout: responseTimeout)

            while true {
                let message = try receiveObject(timeout: responseTimeout)
                if message["method"] is String {
                    try notificationHandler?(message)
                    continue
                }

                if CodexTeamsAppServerConnection.message(message, hasId: requestId) {
                    if let error = message["error"] as? [String: Any] {
                        let message = (error["message"] as? String) ?? "Codex app-server request failed"
                        throw CLIError(message: message)
                    }
                    if let result = message["result"] as? [String: Any] {
                        return result
                    }
                    return ["result": message["result"] ?? NSNull()]
                }
            }
        }

        func receiveObject(timeout: TimeInterval? = nil) throws -> [String: Any] {
            let semaphore = DispatchSemaphore(value: 0)
            let box = CodexTeamsAsyncBox<Result<URLSessionWebSocketTask.Message, Error>>()
            task.receive { result in
                box.set(result)
                semaphore.signal()
            }

            if let timeout,
               semaphore.wait(timeout: .now() + timeout) == .timedOut {
                task.cancel(with: .goingAway, reason: nil)
                throw CLIError(message: "Timed out waiting for Codex app-server response")
            }
            if timeout == nil {
                semaphore.wait()
            }
            guard let result = box.take() else {
                throw CLIError(message: "Codex app-server receive failed")
            }

            switch result {
            case .success(.string(let text)):
                return try Self.decodeObject(Data(text.utf8))
            case .success(.data(let data)):
                return try Self.decodeObject(data)
            case .success:
                throw CLIError(message: "Codex app-server sent an unsupported websocket message")
            case .failure(let error):
                throw error
            }
        }

        private func sendObject(_ object: [String: Any], timeout: TimeInterval = 10) throws {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIError(message: "Failed to encode Codex app-server request")
            }

            let semaphore = DispatchSemaphore(value: 0)
            let box = CodexTeamsAsyncBox<Error?>()
            task.send(.string(text)) { error in
                box.set(error)
                semaphore.signal()
            }

            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                throw CLIError(message: "Timed out sending Codex app-server request")
            }
            if let error = box.take() ?? nil {
                throw error
            }
        }

        private static func decodeObject(_ data: Data) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "Codex app-server sent invalid JSON")
            }
            return object
        }

        private static func message(_ message: [String: Any], hasId requestId: Int) -> Bool {
            if let id = message["id"] as? Int {
                return id == requestId
            }
            if let id = message["id"] as? NSNumber {
                return id.intValue == requestId
            }
            if let id = message["id"] as? String {
                return id == String(requestId)
            }
            return false
        }

        func canResumeThread(threadId: String) -> Bool {
            do {
                _ = try request(
                    method: "thread/resume",
                    params: [
                        "threadId": threadId,
                        "excludeTurns": true
                    ],
                    notificationHandler: nil,
                    responseTimeout: 2
                )
                return true
            } catch {
                return false
            }
        }
    }

    final class CodexTeamsWatcher {
        private let appServerURL: String
        private let workspaceId: String
        private let rootSurfaceId: String
        private let codexExecutable: String
        private let launchPath: String?
        private let maxAutoDepth: Int
        private let socketClient: SocketClient
        private let socketPassword: String?

        private var knownThreadIds = Set<String>()
        private var parentByThreadId: [String: String] = [:]
        private var depthByThreadId: [String: Int] = [:]
        private var pendingByParentThreadId: [String: [CodexTeamsThread]] = [:]
        private var threadById: [String: CodexTeamsThread] = [:]
        private var pendingThreadIds = Set<String>()
        private var openedThreadIds = Set<String>()
        private var readinessProbeThreadIds = Set<String>()
        private var attachableThreadIds = Set<String>()
        private let readinessLock = NSLock()
        private let stateLock = NSLock()
        private var lastAgentSurfaceId: String?
        private var subscribedThreadIds = Set<String>()
        private var approvalItemById: [String: [String: Any]] = [:]
        private var approvalItemOrder: [String] = []
        private var suppressedApprovalKeys = Set<String>()
        private var suppressedApprovalOrder: [String] = []

        init(
            appServerURL: String,
            workspaceId: String,
            rootSurfaceId: String,
            codexExecutable: String,
            launchPath: String?,
            maxAutoDepth: Int,
            socketClient: SocketClient,
            socketPassword: String?
        ) {
            self.appServerURL = appServerURL
            self.workspaceId = workspaceId
            self.rootSurfaceId = rootSurfaceId
            self.codexExecutable = codexExecutable
            self.launchPath = launchPath
            self.maxAutoDepth = max(0, maxAutoDepth)
            self.socketClient = socketClient
            self.socketPassword = socketPassword
        }

        func run() throws {
            guard let url = URL(string: appServerURL) else {
                throw CLIError(message: "Invalid Codex app-server URL: \(appServerURL)")
            }
            let reconcileWaiter = DispatchSemaphore(value: 0)
            while true {
                let connection = CodexTeamsAppServerConnection(url: url)
                connection.resume()
                do {
                    defer { connection.close() }
                    try connection.initialize(
                        clientName: CMUXCLI.codexTeamsWatcherClientName,
                        version: CMUXCLI.codexTeamsClientVersion,
                        optOutNotificationMethods: CMUXCLI.codexTeamsWatcherResumeOptOutNotificationMethods
                    )
                    resetConnectionSubscriptions()
                    try backfillLoadedThreads(connection: connection)
                    try listenForNotifications(connection: connection)
                } catch {
                    fputs("cmux codex-teams watcher connection failed: \(error)\n", stderr)
                }
                _ = reconcileWaiter.wait(timeout: .now() + CMUXCLI.codexTeamsReconcileInterval)
            }
        }

        private func backfillLoadedThreads(connection: CodexTeamsAppServerConnection) throws {
            let loaded = try connection.request(
                method: "thread/loaded/list",
                params: ["limit": 200],
                notificationHandler: { [weak self] message in
                    try self?.handleAppServerMessage(
                        message,
                        connection: connection,
                        allowThreadSubscribe: false
                    )
                }
            )
            let threadIds = loaded["data"] as? [String] ?? []
            for threadId in threadIds {
                do {
                    try subscribeToThreadIfNeeded(threadId, connection: connection)
                } catch {
                    fputs("cmux codex-teams watcher skipped thread \(threadId): \(error)\n", stderr)
                }
            }
        }

        private func listenForNotifications(connection: CodexTeamsAppServerConnection) throws {
            while true {
                let message = try connection.receiveObject()
                try handleAppServerMessage(message, connection: connection)
            }
        }

        private func handleAppServerMessage(
            _ message: [String: Any],
            connection: CodexTeamsAppServerConnection,
            allowThreadSubscribe: Bool = true
        ) throws {
            guard let method = message["method"] as? String else { return }
            cacheApprovalItemIfPresent(message, method: method)
            if let requestId = message["id"],
               try handleApprovalRequest(message, method: method, requestId: requestId, connection: connection) {
                return
            }
            if message["id"] != nil { return }
            guard method.hasPrefix("thread/"),
                  let params = message["params"] as? [String: Any],
                  let threadObject = params["thread"] as? [String: Any],
                  let thread = CMUXCLI.codexTeamsThread(from: threadObject) else {
                return
            }
            try observeThreadSafely(thread)
            if allowThreadSubscribe {
                do {
                    try subscribeToThreadIfNeeded(thread.id, connection: connection)
                } catch {
                    fputs("cmux codex-teams watcher skipped thread \(thread.id): \(error)\n", stderr)
                }
            }
        }

        private func subscribeToThreadIfNeeded(
            _ threadId: String,
            connection: CodexTeamsAppServerConnection
        ) throws {
            stateLock.lock()
            let inserted = subscribedThreadIds.insert(threadId).inserted
            stateLock.unlock()
            guard inserted else { return }

            do {
                let response = try connection.request(
                    method: "thread/resume",
                    params: [
                        "threadId": threadId,
                        "excludeTurns": true
                    ],
                    notificationHandler: { [weak self] message in
                        try self?.handleAppServerMessage(
                            message,
                            connection: connection,
                            allowThreadSubscribe: false
                        )
                    }
                )
                if let threadObject = response["thread"] as? [String: Any],
                   let thread = CMUXCLI.codexTeamsThread(from: threadObject) {
                    try observeThreadSafely(thread)
                }
            } catch {
                stateLock.lock()
                subscribedThreadIds.remove(threadId)
                stateLock.unlock()
                throw error
            }
        }

        private func resetConnectionSubscriptions() {
            stateLock.lock()
            subscribedThreadIds.removeAll(keepingCapacity: true)
            stateLock.unlock()
        }

        private func cacheApprovalItemIfPresent(_ message: [String: Any], method: String) {
            guard method == "item/started" || method == "item/completed" || method == "item/fileChange/patchUpdated",
                  let params = message["params"] as? [String: Any] else {
                return
            }
            if let item = params["item"] as? [String: Any],
               let itemId = CMUXCLI.stringValue(in: item, keys: ["id"]) {
                cacheApprovalItem(item, itemId: itemId)
                return
            }
            guard method == "item/fileChange/patchUpdated",
                  let itemId = CMUXCLI.stringValue(in: params, keys: ["itemId", "item_id"]) else {
                return
            }
            var item = cachedApprovalItem(itemId: itemId) ?? [
                "type": "fileChange",
                "id": itemId
            ]
            if let changes = params["changes"] {
                item["changes"] = changes
            }
            cacheApprovalItem(item, itemId: itemId)
        }

        private func cacheApprovalItem(_ item: [String: Any], itemId: String) {
            stateLock.lock()
            defer { stateLock.unlock() }
            if approvalItemById[itemId] == nil {
                approvalItemOrder.append(itemId)
            }
            approvalItemById[itemId] = CMUXCLI.codexTeamsApprovalItemSnapshot(item)
            while approvalItemOrder.count > CMUXCLI.codexTeamsMaxCachedApprovalItems {
                let evicted = approvalItemOrder.removeFirst()
                approvalItemById.removeValue(forKey: evicted)
            }
        }

        private func cachedApprovalItem(itemId: String) -> [String: Any]? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return approvalItemById[itemId]
        }

        private func handleApprovalRequest(
            _ message: [String: Any],
            method: String,
            requestId: Any,
            connection: CodexTeamsAppServerConnection
        ) throws -> Bool {
            guard CMUXCLI.codexTeamsApprovalMethods.contains(method) else { return false }
            guard let params = message["params"] as? [String: Any] else {
                fputs("cmux codex-teams watcher ignoring malformed approval \(method) request \(CMUXCLI.requestIdString(requestId))\n", stderr)
                return true
            }
            let relatedItem = CMUXCLI.stringValue(in: params, keys: ["itemId", "item_id"])
                .flatMap { cachedApprovalItem(itemId: $0) }
            let suppressionKey = approvalSuppressionKey(method: method, requestId: requestId, params: params)
            if approvalIsSuppressed(suppressionKey) {
                fputs("cmux codex-teams watcher leaving previously unresolved approval \(suppressionKey) to native Codex\n", stderr)
                return true
            }
            let feedEvent = CMUXCLI.codexTeamsFeedEvent(
                method: method,
                requestId: requestId,
                params: params,
                workspaceId: workspaceId,
                relatedItem: relatedItem
            )
            fputs("cmux codex-teams watcher forwarding approval \(method) request \(CMUXCLI.requestIdString(requestId)) to Feed\n", stderr)
            let response: [String: Any]
            do {
                response = try pushCodexApprovalToFeed(event: feedEvent)
            } catch {
                suppressApproval(suppressionKey)
                fputs("cmux codex-teams watcher leaving approval \(suppressionKey) to native Codex after Feed push failed: \(error)\n", stderr)
                return true
            }
            guard let decision = CMUXCLI.codexTeamsPermissionMode(fromFeedPushResponse: response) else {
                suppressApproval(suppressionKey)
                fputs("cmux codex-teams watcher leaving approval \(suppressionKey) to native Codex because Feed did not resolve it\n", stderr)
                return true
            }
            guard let result = CMUXCLI.codexTeamsAppServerApprovalResponse(
                method: method,
                params: params,
                mode: decision
            ) else {
                fputs("cmux codex-teams watcher cannot map Feed decision for \(suppressionKey); leaving it to native Codex\n", stderr)
                return true
            }
            try connection.respond(requestId: requestId, result: result)
            return true
        }

        private func approvalSuppressionKey(method: String, requestId: Any, params: [String: Any]) -> String {
            let stableId = CMUXCLI.stringValue(
                in: params,
                keys: ["approvalId", "approval_id", "itemId", "item_id"]
            ) ?? CMUXCLI.requestIdString(requestId)
            return "\(method):\(stableId)"
        }

        private func approvalIsSuppressed(_ key: String) -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return suppressedApprovalKeys.contains(key)
        }

        private func suppressApproval(_ key: String) {
            stateLock.lock()
            defer { stateLock.unlock() }
            if suppressedApprovalKeys.insert(key).inserted {
                suppressedApprovalOrder.append(key)
            }
            while suppressedApprovalOrder.count > 256 {
                suppressedApprovalKeys.remove(suppressedApprovalOrder.removeFirst())
            }
        }

        private func pushCodexApprovalToFeed(event: [String: Any]) throws -> [String: Any] {
            let feedClient = SocketClient(path: socketClient.socketPath)
            try feedClient.connect()
            defer { feedClient.close() }
            try CMUXCLI.authenticateSocketClientIfNeeded(
                feedClient,
                explicitPassword: socketPassword,
                socketPath: socketClient.socketPath
            )
            return try feedClient.sendV2(method: "feed.push", params: [
                "event": event,
                "wait_timeout_seconds": 120
            ], responseTimeout: 125)
        }

        private func observeThreadSafely(_ thread: CodexTeamsThread) throws {
            stateLock.lock()
            defer { stateLock.unlock() }
            try observeThread(thread)
        }

        private func observeThread(_ thread: CodexTeamsThread) throws {
            threadById[thread.id] = thread
            if knownThreadIds.contains(thread.id) {
                if let spawn = thread.spawn {
                    if parentByThreadId[thread.id] == nil {
                        try observeSpawn(thread, spawn: spawn)
                    } else if !openedThreadIds.contains(thread.id) {
                        try openObservedSubagent(thread, spawn: spawn)
                    }
                }
                return
            }

            knownThreadIds.insert(thread.id)
            if let spawn = thread.spawn {
                try observeSpawn(thread, spawn: spawn)
            } else {
                depthByThreadId[thread.id] = 0
            }

            try drainPendingChildren(parentThreadId: thread.id)
        }

        private func observeSpawn(
            _ thread: CodexTeamsThread,
            spawn: CodexTeamsSpawn
        ) throws {
            parentByThreadId[thread.id] = spawn.parentThreadId
            guard knownThreadIds.contains(spawn.parentThreadId),
                  depthByThreadId[spawn.parentThreadId] != nil else {
                if pendingThreadIds.insert(thread.id).inserted {
                    pendingByParentThreadId[spawn.parentThreadId, default: []].append(thread)
                }
                return
            }
            pendingThreadIds.remove(thread.id)
            try openObservedSubagent(thread, spawn: spawn)
        }

        private func drainPendingChildren(parentThreadId: String) throws {
            guard let pending = pendingByParentThreadId.removeValue(forKey: parentThreadId) else {
                return
            }
            for child in pending {
                pendingThreadIds.remove(child.id)
                guard let spawn = child.spawn else { continue }
                try openObservedSubagent(child, spawn: spawn)
                try drainPendingChildren(parentThreadId: child.id)
            }
        }

        private func openObservedSubagent(
            _ thread: CodexTeamsThread,
            spawn: CodexTeamsSpawn
        ) throws {
            let parentDepth = depthByThreadId[spawn.parentThreadId]
            let depth = parentDepth.map { $0 + 1 } ?? max(spawn.sourceDepth ?? 1, 1)
            depthByThreadId[thread.id] = depth
            guard depth <= maxAutoDepth else { return }
            guard !openedThreadIds.contains(thread.id) else { return }
            guard CMUXCLI.codexTeamsThreadMayBeAttachable(thread) else { return }
            guard codexTeamsConsumeAttachableThreadId(thread.id) else {
                codexTeamsScheduleReadinessProbe(threadId: thread.id)
                return
            }

            do {
                try openSubagent(thread, spawn: spawn, depth: depth)
            } catch {
                if lastAgentSurfaceId != nil {
                    lastAgentSurfaceId = nil
                    try openSubagent(thread, spawn: spawn, depth: depth)
                } else {
                    throw error
                }
            }
            openedThreadIds.insert(thread.id)
        }

        private func codexTeamsScheduleReadinessProbe(threadId: String) {
            readinessLock.lock()
            if attachableThreadIds.contains(threadId)
                || readinessProbeThreadIds.contains(threadId)
                || openedThreadIds.contains(threadId) {
                readinessLock.unlock()
                return
            }
            readinessProbeThreadIds.insert(threadId)
            readinessLock.unlock()

            let appServerURL = appServerURL
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let isAttachable = CMUXCLI.codexTeamsThreadCanResume(
                    appServerURL: appServerURL,
                    threadId: threadId
                )
                guard let self else { return }
                self.readinessLock.lock()
                self.readinessProbeThreadIds.remove(threadId)
                if isAttachable {
                    self.attachableThreadIds.insert(threadId)
                }
                self.readinessLock.unlock()
                guard isAttachable else { return }
                do {
                    try self.openAttachableThread(threadId: threadId)
                } catch {
                    fputs("cmux codex-teams watcher failed to open ready subagent \(threadId): \(error)\n", stderr)
                }
            }
        }

        private func openAttachableThread(threadId: String) throws {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard let thread = threadById[threadId],
                  let spawn = thread.spawn,
                  parentByThreadId[threadId] != nil else {
                return
            }
            try openObservedSubagent(thread, spawn: spawn)
        }

        private func codexTeamsConsumeAttachableThreadId(_ threadId: String) -> Bool {
            readinessLock.lock()
            defer { readinessLock.unlock() }
            guard attachableThreadIds.remove(threadId) != nil else {
                return false
            }
            return true
        }

        private func openSubagent(
            _ thread: CodexTeamsThread,
            spawn: CodexTeamsSpawn,
            depth: Int
        ) throws {
            let commandText = CMUXCLI.codexTeamsResumeCommandText(
                codexExecutable: codexExecutable,
                appServerURL: appServerURL,
                threadId: thread.id,
                parentThreadId: spawn.parentThreadId,
                depth: depth,
                launchPath: launchPath
            )
            guard let startupScript = CMUXCLI.codexTeamsStartupScript(commandText: commandText, cwd: thread.cwd) else {
                throw CLIError(message: "Failed to create Codex subagent startup script")
            }

            let targetSurfaceId = lastAgentSurfaceId ?? rootSurfaceId
            let direction = lastAgentSurfaceId == nil ? "right" : "down"
            var splitParams: [String: Any] = [
                "workspace_id": workspaceId,
                "surface_id": targetSurfaceId,
                "direction": direction,
                "focus": false,
                "initial_command": startupScript,
                "tmux_start_command": commandText,
                "startup_environment": [
                    managedSubagentEnvironmentKey: "1",
                    codexTeamsThreadEnvironmentKey: thread.id,
                    codexTeamsParentThreadEnvironmentKey: spawn.parentThreadId,
                    codexTeamsDepthEnvironmentKey: String(max(1, depth))
                ]
            ]
            if let cwd = thread.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                splitParams["working_directory"] = cwd
            }

            let created = try socketClient.sendV2(method: "surface.split", params: splitParams)
            guard let surfaceId = created["surface_id"] as? String else {
                throw CLIError(message: "surface.split did not return surface_id")
            }
            lastAgentSurfaceId = surfaceId

            do {
                _ = try socketClient.sendV2(method: "tab.action", params: [
                    "workspace_id": workspaceId,
                    "surface_id": surfaceId,
                    "action": "rename",
                    "title": CMUXCLI.codexTeamsTitle(thread: thread, spawn: spawn, depth: depth)
                ])
            } catch {
                // The subagent pane already exists, so a rename failure should not stop watching.
            }
            do {
                _ = try socketClient.sendV2(method: "workspace.equalize_splits", params: [
                    "workspace_id": workspaceId,
                    "orientation": "vertical"
                ])
            } catch {
                // Layout polish is best-effort after the pane is opened.
            }
        }
    }

}
