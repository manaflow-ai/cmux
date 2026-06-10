import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - Socket server lifecycle, auth, and client handling
extension TerminalController {
    /// Check if `pid` is a descendant of this process by walking the process tree.
    nonisolated func isDescendant(_ pid: pid_t) -> Bool {
        transport.isProcessDescendant(pid, of: myPid)
    }

    private nonisolated static func shouldCaptureSocketListenerFailure(
        message: String,
        stage: String,
        path: String,
        errnoCode: Int32?
    ) -> Bool {
        let key = "\(message)|\(stage)|\(path)|\(errnoCode.map(String.init) ?? "none")"
        let now = Date()
        socketListenerFailureCaptureLock.lock()
        defer { socketListenerFailureCaptureLock.unlock() }
        if let lastCapturedAt = socketListenerFailureLastCapturedAt[key],
           now.timeIntervalSince(lastCapturedAt) < socketListenerFailureCaptureCooldown {
            return false
        }
        socketListenerFailureLastCapturedAt[key] = now
        return true
    }

    /// Builds the package server's host-callback seam. `target` is filled in
    /// at the end of `init`; no listener event can fire before `start`.
    nonisolated static func makeSocketServerEvents(
        target: ServerEventTarget
    ) -> SocketControlServerEvents {
        SocketControlServerEvents(
            breadcrumb: { message, data in
                sentryBreadcrumb(message, category: "socket", data: data)
            },
            failure: { message, stage, errnoCode, data in
                sentryBreadcrumb(message, category: "socket", data: data)
                guard shouldCaptureSocketListenerFailure(
                    message: message,
                    stage: stage,
                    path: data["path"] as? String ?? "",
                    errnoCode: errnoCode
                ) else {
                    return
                }
                sentryCaptureError(message, category: "socket", data: data, contextKey: "socket_listener")
            },
            listenerDidStart: { path, _ in
                target.controller?.socketListenerDidStart(path: path)
            },
            recordLastSocketPath: { path in
                SocketControlSettings.recordLastSocketPath(path)
            },
            clientAccepted: { socket, peerPid in
                guard let controller = target.controller else {
                    close(socket)
                    return
                }
                controller.spawnClientHandler(socket: socket, peerPid: peerPid)
            },
            pathMissingDetected: { path, generation in
                Task { @MainActor in
                    target.controller?.restartSocketListenerIfPathMissing(path: path, generation: generation)
                }
            },
            rearmRequested: { generation, errnoCode, consecutiveFailures, delayMs in
                target.controller?.scheduleListenerRearm(
                    generation: generation,
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures,
                    delayMs: delayMs
                )
            }
        )
    }

    /// Inject the auth graph. Call once at the composition root, before the
    /// socket listener accepts auth commands.
    @MainActor
    func attachAuth(coordinator: AuthCoordinator, browserSignIn: HostBrowserSignInFlow) {
        self.authCoordinator = coordinator
        self.browserSignInFlow = browserSignIn
    }


    func start(
        tabManager: TabManager,
        socketPath: String,
        accessMode: SocketControlMode,
        preserveAcceptFailureStreak: Bool = false
    ) {
        self.tabManager = tabManager
        socketServer.start(
            socketPath: socketPath,
            accessMode: accessMode,
            preserveAcceptFailureStreak: preserveAcceptFailureStreak
        )
    }

    /// Invoked by the server at the exact point the legacy `start` posted
    /// `.socketListenerDidStart`: after the running-state commit, before the
    /// path monitor and accept source arm. Every start path runs on the main
    /// thread (`start` is `@MainActor`; rearm fires on the main queue; the
    /// path-missing restart hops through a `@MainActor` task).
    nonisolated func socketListenerDidStart(path: String) {
        MainActor.assumeIsolated {
            NotificationCenter.default.post(
                name: .socketListenerDidStart,
                object: self,
                userInfo: ["path": path]
            )

            // Wire batched port scanner results back to workspace state.
            PortScanner.shared.onPortsUpdated = { [weak self] workspaceId, panelId, ports in
                guard let self, let tabManager = self.tabManager else { return }
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
                let validSurfaceIds = Set(workspace.panels.keys)
                guard validSurfaceIds.contains(panelId) else { return }
                workspace.surfaceListeningPorts[panelId] = ports.isEmpty ? nil : ports
                workspace.recomputeListeningPorts()
            }
            PortScanner.shared.onAgentPortsUpdated = { [weak self] workspaceId, ports in
                guard let self, let tabManager = self.tabManager else { return }
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
                if workspace.agentListeningPorts != ports {
                    workspace.agentListeningPorts = ports
                    workspace.recomputeListeningPorts()
                }
            }
            PortScanner.shared.agentPIDsProvider = { [weak self] workspaceIds in
                guard let self, let tabManager = self.tabManager else { return [:] }
                var pidsByWorkspace: [UUID: Set<Int>] = [:]
                for workspaceId in workspaceIds {
                    guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { continue }
                    let pids = Set(workspace.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
                    if !pids.isEmpty {
                        pidsByWorkspace[workspaceId] = pids
                    }
                }
                return pidsByWorkspace
            }
        }
    }

    nonisolated func socketListenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
        socketServer.listenerHealth(expectedSocketPath: expectedSocketPath)
    }

    private func restartSocketListenerIfPathMissing(path: String, generation: UInt64) {
        guard let tabManager else { return }
        let restartMode = socketServer.accessMode
        guard socketServer.shouldRestartForMissingPath(path: path, generation: generation) else { return }

        sentryBreadcrumb(
            "socket.listener.restart",
            category: "socket",
            data: [
                "mode": restartMode.rawValue,
                "path": path,
                "source": "path_monitor",
                "generation": generation
            ]
        )
        stop()
        start(tabManager: tabManager, socketPath: path, accessMode: restartMode)
    }

    nonisolated func stop() {
        socketServer.stop()
    }

    private nonisolated func writeSocketResponse(_ response: String, to socket: Int32) -> Bool {
        let payload = response + "\n"
        return transport.writeAll(Data(payload.utf8), to: socket)
    }

    private nonisolated func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    private nonisolated func passwordLoginV1ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return "ERROR: Password mode is enabled but no socket password is configured in Settings."
        }

        let provided: String
        if lowered == "auth" {
            provided = ""
        } else {
            provided = String(command.dropFirst(5))
        }
        guard !provided.isEmpty else {
            return "ERROR: Missing password. Usage: auth <password>"
        }
        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return "ERROR: Invalid password"
        }
        authenticated = true
        return "OK: Authenticated"
    }

    private nonisolated func passwordLoginV2ResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        let id = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard method == "auth.login" else {
            return nil
        }

        guard let params = dict["params"] as? [String: Any],
              let provided = params["password"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "auth.login requires params.password")
        }

        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        authenticated = true
        return v2Ok(id: id, result: ["authenticated": true])
    }

    private nonisolated func authResponseIfNeeded(for command: String, authenticated: inout Bool) -> String? {
        guard socketServer.accessMode.requiresPasswordAuth else {
            return nil
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v2Response
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(for: command, authenticated: &authenticated) {
            return v1Response
        }
        if !authenticated {
            return passwordAuthRequiredResponse(for: command)
        }
        return nil
    }

    /// Interim bridged view of a decoded `ControlRequest` with Foundation
    /// (`Any`) field shapes, so the existing command bodies keep their
    /// `[String: Any]` params until they migrate onto the typed DTOs in the
    /// ControlCommandCoordinator stage.
    struct V2SocketRequest {
        let id: Any?
        let method: String
        let params: [String: Any]

        init(bridging request: ControlRequest) {
            id = request.id.map(\.foundationObject)
            method = request.method
            params = request.params.mapValues { $0.foundationObject }
        }
    }

    nonisolated func parseV2SocketRequest(_ command: String) -> V2SocketRequest? {
        guard let request = Self.v2Parser.lenientRequest(fromLine: command) else {
            return nil
        }
        return V2SocketRequest(bridging: request)
    }

    nonisolated func socketWorkerV2ResponseIfHandled(for command: String) -> (handled: Bool, response: String?) {
        guard let request = parseV2SocketRequest(command),
              Self.executionPolicy(forV2Method: request.method).runsOnSocketWorker else {
            return (false, nil)
        }

        return withSocketCommandPolicy(commandKey: request.method, isV2: true, params: request.params) {
            if let workspaceParamError = v2UnsupportedWorkspaceAliasError(method: request.method, params: request.params) {
                return (true, v2Result(id: request.id, workspaceParamError))
            }
            if request.method == "feed.push", request.id == nil {
                guard let waitTimeout = Self.feedPushWaitTimeoutSeconds(params: request.params) else {
                    return (true, v2Error(
                        id: request.id,
                        code: "invalid_params",
                        message: "feed.push wait_timeout_seconds must be numeric and between 0 and 120"
                    ))
                }
                guard waitTimeout == 0 else {
                    return (true, v2Error(
                        id: request.id,
                        code: "invalid_params",
                        message: "feed.push without an id requires wait_timeout_seconds 0"
                    ))
                }
                _ = socketWorkerV2Response(request)
                return (true, nil)
            }
            return (true, socketWorkerV2Response(request))
        }
    }

    private nonisolated static func feedPushWaitTimeoutSeconds(params: [String: Any]) -> TimeInterval? {
        guard let rawTimeout = params["wait_timeout_seconds"] else {
            return 0
        }
        let seconds: Double?
        if let number = rawTimeout as? NSNumber {
            seconds = number.doubleValue
        } else if let value = rawTimeout as? Double {
            seconds = value
        } else if let value = rawTimeout as? Int {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 120 else {
            return nil
        }
        return seconds
    }

    private nonisolated func socketWorkerV2Response(_ request: V2SocketRequest) -> String {
        switch request.method {
        case "auth.status":
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                await self?.authCoordinator?.awaitBootstrapped()
                semaphore.signal()
            }
            semaphore.wait()
            return v2Ok(id: request.id, result: v2AuthStatusPayload(timedOut: false))
        case "auth.begin_sign_in":
            let timeoutSeconds = (request.params["timeout_seconds"] as? Double) ?? 300
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var signedIn = false
            Task { @MainActor [weak self] in
                signedIn = await self?.browserSignInFlow?.signIn(
                    timeout: timeoutSeconds
                ) ?? false
                semaphore.signal()
            }
            semaphore.wait()
            return v2Ok(id: request.id, result: v2AuthStatusPayload(timedOut: !signedIn))
        case "auth.sign_out":
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                await self?.browserSignInFlow?.signOut(timeout: 5)
                semaphore.signal()
            }
            semaphore.wait()
            return v2Ok(id: request.id, result: v2AuthStatusPayload(timedOut: false))
        case "feedback.submit":
            return v2Result(id: request.id, v2FeedbackSubmit(params: request.params))
        case "feed.push":
            return v2Result(id: request.id, v2FeedPush(params: request.params))
        case "feed.permission.reply":
            return v2Result(id: request.id, v2FeedPermissionReply(params: request.params))
        case "feed.question.reply":
            return v2Result(id: request.id, v2FeedQuestionReply(params: request.params))
        case "feed.exit_plan.reply":
            return v2Result(id: request.id, v2FeedExitPlanReply(params: request.params))
        case "browser.download.wait":
            return v2Result(id: request.id, v2BrowserDownloadWaitOnSocketWorker(params: request.params))
        case "browser.profiles.list":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.list(params: request.params)
            }
        case "browser.profiles.create":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.create(params: request.params)
            }
        case "browser.profiles.rename":
            return v2VmCall(id: request.id, timeoutSeconds: 30) {
                try await BrowserProfileAutomation.rename(params: request.params)
            }
        case "browser.profiles.clear":
            return v2VmCall(id: request.id, timeoutSeconds: 120) {
                try await BrowserProfileAutomation.clear(params: request.params)
            }
        case "browser.profiles.delete":
            return v2VmCall(id: request.id, timeoutSeconds: 120) {
                try await BrowserProfileAutomation.delete(params: request.params)
            }
        case "browser.import.cookies":
            return v2VmCall(id: request.id, timeoutSeconds: 10 * 60) {
                let outcome = try await BrowserImportAutomation.importCookies(params: request.params)
                return outcome.socketPayload
            }
        case "mobile.attach_ticket.create":
            return v2AsyncResultCall(id: request.id, timeoutSeconds: 30) {
                await self.v2MobileAttachTicketCreate(params: request.params)
            }
        case "system.ping":
            return v2Ok(id: request.id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: request.id, result: v2Capabilities())
        case "system.top":
            return v2Result(id: request.id, v2SystemTop(params: request.params))
        case "system.memory":
            return v2Result(id: request.id, v2SystemMemory(params: request.params))
        case "workspace.remote.pty_sessions":
            return v2Result(id: request.id, v2WorkspaceRemotePTYSessions(params: request.params))
        case "workspace.remote.pty_close":
            return v2Result(id: request.id, v2WorkspaceRemotePTYClose(params: request.params))
        case "workspace.remote.pty_detach":
            return v2Result(id: request.id, v2WorkspaceRemotePTYDetach(params: request.params))
        case "workspace.remote.pty_bridge":
            return v2Result(id: request.id, v2WorkspaceRemotePTYBridge(params: request.params))
        case "workspace.remote.pty_resize":
            return v2Result(id: request.id, v2WorkspaceRemotePTYResize(params: request.params))
        case "sidebar.custom.validate":
            return v2Result(id: request.id, v2CustomSidebarValidate(params: request.params))
        case "sidebar.custom.reload":
            return v2Result(id: request.id, v2CustomSidebarReload(params: request.params))
        case "sidebar.custom.select":
            return v2Result(id: request.id, v2CustomSidebarSelect(params: request.params))
#if DEBUG
        case "debug.sidebar.simulate_drag":
            return v2Result(id: request.id, v2DebugSidebarSimulateDrag(params: request.params))
#endif
        case let method where method.hasPrefix("vm."):
            return socketWorkerCloudVMResponse(method: method, id: request.id, params: request.params)
        default:
            return v2Error(id: request.id, code: "method_not_found", message: "Unknown method")
        }
    }

    private nonisolated func spawnClientHandler(socket clientSocket: Int32, peerPid: pid_t?) {
        Thread.detachNewThread { [weak self] in
            guard let self else {
                close(clientSocket)
                return
            }
            self.handleClient(clientSocket, peerPid: peerPid)
        }
    }

    private nonisolated func scheduleListenerRearm(
        generation: UInt64,
        errnoCode: Int32,
        consecutiveFailures: Int,
        delayMs: Int
    ) {
        let deadline = DispatchTime.now() + .milliseconds(delayMs)
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let tabManager = self.tabManager else { return }
                guard let restartPath = self.socketServer.claimPendingRearm(
                    generation: generation,
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures,
                    delayMs: delayMs
                ) else { return }

                let restartMode = self.socketServer.accessMode

                self.stop()
                self.start(
                    tabManager: tabManager,
                    socketPath: restartPath,
                    accessMode: restartMode,
                    preserveAcceptFailureStreak: true
                )
            }
        }
    }

    private nonisolated func handleClient(_ socket: Int32, peerPid: pid_t? = nil) {
        defer { close(socket) }

        // In cmuxOnly mode, verify the connecting process is a descendant of cmux.
        // In allowAll mode (env-var only), skip the ancestry check.
        if socketServer.accessMode == .cmuxOnly {
            // Use pre-captured peer PID if available (captured in accept loop before
            // the peer can disconnect), falling back to live lookup.
            let pid = peerPid ?? transport.peerProcessID(of: socket)
            if let pid {
                guard isDescendant(pid) else {
                    _ = writeSocketResponse(
                        "ERROR: Access denied — only processes started inside cmux can connect",
                        to: socket
                    )
                    return
                }
            }
            // If pid is nil, LOCAL_PEERPID failed (peer disconnected before we
            // could read it — common with ncat --send-only). We still verify the
            // peer runs as the same user via LOCAL_PEERCRED. This is the same
            // security boundary as the socket file permissions (0600), so it does
            // not widen the attack surface. We also require that the peer actually
            // sent data (checked in the read loop below) — a connect-only probe
            // with no data is harmless.
            if pid == nil {
                guard transport.peerHasSameUID(socket) else {
                    _ = writeSocketResponse(
                        "ERROR: Unable to verify client process",
                        to: socket
                    )
                    return
                }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = ""
        var authenticated = false

        while socketServer.isRunning {
            let bytesRead = read(socket, &buffer, buffer.count - 1)
            guard bytesRead > 0 else { break }

            let chunk = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newlineIndex])
                pending = String(pending[pending.index(after: newlineIndex)...])
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                var shouldCloseSocket = false
                autoreleasepool {
                    if isEventsStreamRequest(trimmed) {
                        if let response = authResponseIfNeeded(for: trimmed, authenticated: &authenticated) {
                            if !writeSocketResponse(response, to: socket) {
                                shouldCloseSocket = true
                            }
                            return
                        }
                        handleEventsStreamRequest(trimmed, socket: socket)
                        shouldCloseSocket = true
                        return
                    }

                    let result = processSocketLine(trimmed, authenticated: authenticated)
                    authenticated = result.authenticated
                    if let response = result.response {
                        let didWriteResponse = writeSocketResponse(response, to: socket)
                        publishSocketEvents(command: trimmed, response: response)
                        if !didWriteResponse {
                            shouldCloseSocket = true
                        }
                    }
                }
                if shouldCloseSocket {
                    return
                }
            }
        }
    }

    private nonisolated func processSocketLine(
        _ command: String,
        authenticated: Bool
    ) -> SocketLineProcessingResult {
#if DEBUG
        let debugInfo = Self.socketCommandDebugInfo(command)
        let debugStart = DispatchTime.now().uptimeNanoseconds
        let debugLoggingEnabled = Self.socketCommandDebugLoggingEnabled()
        if debugLoggingEnabled {
            Self.debugLogSocketCommand(
                "socket.command.begin proto=\(debugInfo.protocolName) method=\(debugInfo.commandKey)"
            )
        }
#endif
        var nextAuthenticated = authenticated
        if let response = authResponseIfNeeded(for: command, authenticated: &nextAuthenticated) {
#if DEBUG
            Self.debugLogSocketCommandEndIfNeeded(
                debugInfo: debugInfo,
                startedAt: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            )
#endif
            return SocketLineProcessingResult(response: response, authenticated: nextAuthenticated)
        }

        let response = processCommandUsingSocketExecutionPolicy(command)
#if DEBUG
        if let response {
            Self.debugLogSocketCommandEndIfNeeded(
                debugInfo: debugInfo,
                startedAt: debugStart,
                response: response,
                loggingEnabled: debugLoggingEnabled
            )
        }
#endif
        return SocketLineProcessingResult(response: response, authenticated: nextAuthenticated)
    }

}
