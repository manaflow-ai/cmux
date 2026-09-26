import CmuxControlSocket
import CmuxBrowser
import Foundation

/// Async socket-dispatch helpers kept separate from the legacy synchronous
/// dispatcher. Socket connections use these methods; in-process callers retain
/// the synchronous `handleSocketLine` contract.
extension TerminalController {
    /// Processes one authenticated socket line without synchronously waiting
    /// for the main actor. The returned authorization value is connection
    /// local and must be fed into the next line in FIFO order.
    nonisolated func processSocketLineAsync(
        _ command: String,
        passwordAuthorization: SocketPasswordAuthorization,
        rateLimiter: ControlClientRateLimiter
    ) async -> (response: String?, passwordAuthorization: SocketPasswordAuthorization) {
        var nextPasswordAuthorization = passwordAuthorization
        if let response = authResponseIfNeeded(
            for: command,
            passwordAuthorization: &nextPasswordAuthorization
        ) {
            return (response, nextPasswordAuthorization)
        }

        if let method = Self.socketPollingMethod(in: command),
           case .limited(let retryAfterMilliseconds) = await rateLimiter.admit(method: method) {
            return (
                Self.socketRateLimitedResponse(
                    command: command,
                    retryAfterMilliseconds: retryAfterMilliseconds
                ),
                nextPasswordAuthorization
            )
        }

        let response = await processCommandUsingSocketExecutionPolicyAsync(command)
        return (response, nextPasswordAuthorization)
    }

    /// Async counterpart of the socket execution-policy dispatcher. Parsing
    /// and JSON encoding remain on the connection task; only the minimal
    /// main-actor action is awaited, and that hop is deadline-bounded: a
    /// stalled main thread answers with a structured `timeout` error instead
    /// of holding the connection (and its pool slot) forever (#13369).
    nonisolated func processCommandUsingSocketExecutionPolicyAsync(
        _ command: String
    ) async -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            let request: ControlRequest
            switch Self.v2Parser.request(fromLine: trimmed) {
            case .failure(let parseError):
                return Self.v2Encoder.response(for: parseError)
            case .success(let parsed):
                request = parsed
            }
            do {
                return try await processV2CommandUsingSocketExecutionPolicyAsync(request)
            } catch let timeout as SocketMainActorHopTimeout {
                return await socketMainHopTimeoutResponse(
                    id: request.id,
                    method: request.method,
                    isV2: true,
                    error: timeout
                )
            } catch {
                // Only cancellation reaches here: the connection is being torn
                // down, so there is nobody left to answer.
                return nil
            }
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let commandName = parts.first?.lowercased() ?? ""
        do {
            return try await processV1CommandUsingSocketExecutionPolicyAsync(
                command,
                commandName: commandName,
                args: parts.count > 1 ? parts[1] : ""
            )
        } catch let timeout as SocketMainActorHopTimeout {
            return await socketMainHopTimeoutResponse(
                id: nil,
                method: commandName,
                isV2: false,
                error: timeout
            )
        } catch {
            return nil
        }
    }

    private nonisolated func processV2CommandUsingSocketExecutionPolicyAsync(
        _ request: ControlRequest
    ) async throws -> String? {
        let relayAuthorization = try await authorizeRemoteRelayRequestAsync(request)
        if let errorResponse = relayAuthorization.errorResponse {
            return errorResponse
        }
        let authorizedRequest = relayAuthorization.request
        let automationOrigin = CmuxAutomationInvocationContext.eventOrigin
        if let focusError = Self.focusSuppressionResponse(
            method: authorizedRequest.method,
            id: authorizedRequest.id.map(\.foundationObject),
            params: authorizedRequest.params.mapValues(\.foundationObject)
        ) {
            return focusError
        }
        if let workspaceParamError = v2UnsupportedWorkspaceAliasError(
            method: authorizedRequest.method,
            params: authorizedRequest.params.mapValues(\.foundationObject)
        ) {
            return v2Result(
                id: authorizedRequest.id?.foundationObject,
                workspaceParamError
            )
        }

        let policy = Self.executionPolicy(forV2Method: authorizedRequest.method)
        return try await CmuxAutomationInvocationContext.$eventOrigin.withValue(automationOrigin) {
            try await withSocketCommandPolicyAsync(
                commandKey: authorizedRequest.method,
                isV2: true,
                params: authorizedRequest.params
            ) {
                // Native browser keys stay on the asynchronous MainActor
                // path: WebKit/AppKit require main-actor delivery, while
                // the socket worker remains suspendable during readiness.
                // Opaque keys intentionally continue through the legacy
                // compatibility worker handler.
                if let action = self.browserKeyboardAction(for: authorizedRequest.method),
                   let rawKey = authorizedRequest.params["key"]?.foundationObject as? String,
                   let event = BrowserKeyboardEvent(rawKey: rawKey),
                   event.nativeKey != nil {
                    return await self.v2BrowserKeyboardNativeResponse(
                        request: authorizedRequest,
                        event: event,
                        action: action
                    )
                }
                if authorizedRequest.method == "surface.sync_codex_native_title" {
                    return try await self.v2MainAsync {
                        self.v2Result(
                            id: authorizedRequest.id?.foundationObject,
                            self.v2SurfaceSyncCodexNativeTitle(
                                params: authorizedRequest.params.mapValues(\.foundationObject)
                            )
                        )
                    }
                }
                if policy.runsOnSocketWorker {
                    // Terminal rename performs an awaited cloud-link mutation. Keep the
                    // actual socket connection task asynchronous instead of parking a
                    // worker thread behind the legacy semaphore bridge.
                    if authorizedRequest.method == "vm.terminal_rename" {
                        return await self.socketCloudRenameResponseWithDeadline(
                            id: authorizedRequest.id
                        ) {
                            await self.socketWorkerVMTerminalRenameResponseAsync(authorizedRequest)
                        }
                    }
                    if authorizedRequest.method == "vm.tab_rename" {
                        return await self.socketCloudRenameResponseWithDeadline(
                            id: authorizedRequest.id
                        ) {
                            await self.socketWorkerVMTabRenameResponseAsync(authorizedRequest)
                        }
                    }
                    return try await self.socketWorkerV2ResponseAsync(authorizedRequest)
                }
                return try await self.processParsedV2CommandAsync(authorizedRequest)
            }
        }
    }

    private nonisolated func processV1CommandUsingSocketExecutionPolicyAsync(
        _ command: String,
        commandName: String,
        args: String
    ) async throws -> String? {
        guard !commandName.isEmpty else {
            return try await v2MainAsync {
                self.processCommand(command)
            }
        }
        let policy = ControlCommandExecutionPolicy(forV1Command: commandName)
        return try await withSocketCommandPolicyAsync(
            commandKey: commandName,
            isV2: false,
            params: commandName == "right_sidebar"
                ? ["args": .string(args)]
                : [:]
        ) {
            if policy.runsOnSocketWorker {
                // The existing worker implementation is synchronous and may
                // block on `v2MainSync`, so it runs on the blocking worker
                // lane, serial within this connection task, preserving v1
                // FIFO semantics.
                let worker = await self.runSocketWorkerBlockingBody {
                    self.socketWorkerV1ResponseIfHandled(
                        cmd: commandName,
                        args: args
                    )
                }
                if worker.handled { return worker.response }
            }
            return try await self.v2MainAsync {
                self.processCommand(command)
            }
        }
    }
    /// Handles a v2 worker request. Snapshot hits are entirely off-main;
    /// topology misses use the coordinator's typed result seam once and cache
    /// that result for subsequent polls. Legacy worker methods remain on their
    /// established worker path.
    private nonisolated func socketWorkerV2ResponseAsync(
        _ request: ControlRequest
    ) async throws -> String? {
        if request.method == "auth.team.list"
            || request.method == "auth.team.use"
            || request.method == "auth.team.create" {
            return try await v2AuthTeamResponseAsync(request)
        }
        if request.method == "surface.read_selection" {
            return await socketSurfaceSelectionResponseAsync(request)
        }
        if request.method == "feed.jump" {
            guard let result = await controlCommandCoordinator
                .handleSocketWorkerFeedAsync(request, context: self) else {
                return Self.v2Encoder.error(
                    id: request.id,
                    code: "method_not_found",
                    message: String(
                        localized: "socket.error.unknownMethod",
                        defaultValue: "Unknown method"
                    ),
                    data: nil
                )
            }
            return Self.v2Encoder.response(id: request.id, result)
        }
        if request.method == "agent.restore.admit" {
            return try await agentRestoreAdmissionResponse(request)
        }
        if request.method == "agent.restore.release" {
            return try await agentRestoreAdmissionReleaseResponse(request)
        }
        if request.params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] == nil,
           ControlCommandExecutionPolicy.servesFromPublishedReadSnapshot(method: request.method),
           let snapshotResult = socketReadSnapshotStore.response(
                method: request.method,
                params: request.params,
                maximumAgeNanoseconds: Self.snapshotMaximumAgeNanoseconds(
                    for: request.method
                )
           ) {
            return Self.v2Encoder.response(id: request.id, snapshotResult)
        }
        if ControlCommandExecutionPolicy.servesFromPublishedReadSnapshot(method: request.method),
           let coordinatorResult = try await v2MainAsync({
               self.controlCommandCoordinator.handleSocketWorkerV2(
                   request,
                   context: self
               )
           }) {
            socketReadSnapshotStore.publishResponse(
                method: request.method,
                params: request.params,
                result: coordinatorResult
            )
            return Self.v2Encoder.response(id: request.id, coordinatorResult)
        }

        if Self.socketWorkerCoordinatorHopMethods.contains(request.method) {
            let response = try await v2MainAsync {
                self.socketWorkerV2Response(handling: request)
            }
            Task { @MainActor [weak self] in
                self?.scheduleSocketReadSnapshotRefresh()
            }
            return response
        }

        if request.method == "system.top" {
            let response = try await v2SystemTopAsync(request)
            if let result = Self.controlCallResult(fromEncodedResponse: response) {
                socketReadSnapshotStore.publishResponse(
                    method: request.method,
                    params: request.params,
                    result: result
                )
            }
            return response
        }
        if request.method == "system.memory" {
            let result = try await v2SystemMemory(params: request.params.mapValues(\.foundationObject))
            let typedResult = Self.controlCallResult(fromLegacy: result)
            socketReadSnapshotStore.publishResponse(
                method: request.method,
                params: request.params,
                result: typedResult
            )
            return Self.v2Encoder.response(id: request.id, typedResult)
        }

        if request.method == "surface.read_text" {
            // These legacy bodies still return Foundation-shaped values. Run
            // the miss on the main actor only when no published snapshot exists;
            // steady-state polling takes the branch above and never enters
            // this fallback.
            let response = try await v2MainAsync {
                self.socketWorkerV2Response(
                    handling: ControlRequest(
                        id: request.id,
                        method: request.method,
                        params: request.params
                    )
                )
            }
            if let response,
               let result = Self.controlCallResult(fromEncodedResponse: response) {
                socketReadSnapshotStore.publishResponse(
                    method: request.method,
                    params: request.params,
                    result: result
                )
            }
            return response
        }

        // Legacy synchronous worker bodies may block in `v2MainSync`; keep
        // them off the cooperative pool.
        return await runSocketWorkerBlockingBody {
            self.socketWorkerV2Response(handling: request)
        }
    }

    /// Runs the live selection read without parking the cooperative executor.
    /// Synchronous in-process callers keep the legacy adapter, but socket
    /// connections race the read against a cancellable request deadline.
    private nonisolated func socketSurfaceSelectionResponseAsync(
        _ request: ControlRequest
    ) async -> String {
        let (responses, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let operation = Task {
            let result = await self.v2SurfaceReadSelection(params: request.params)
            continuation.yield(self.v2Result(id: request.id?.foundationObject, result))
            continuation.finish()
        }
        let deadlineClock = ContinuousClock()
        let timeout = Task {
            do {
                // Genuine request deadline; cancellation tears down the sleeper.
                try await deadlineClock.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            continuation.yield(self.v2Error(
                id: request.id?.foundationObject,
                code: "timeout",
                message: String(
                    localized: "socket.surfaceSelection.timeout",
                    defaultValue: "Request timed out after 5 seconds"
                )
            ))
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in
            operation.cancel()
            timeout.cancel()
        }

        let response = await withTaskCancellationHandler(
            operation: {
                var iterator = responses.makeAsyncIterator()
                return await iterator.next()
            },
            onCancel: {
                operation.cancel()
                timeout.cancel()
                continuation.finish()
            }
        )
        operation.cancel()
        timeout.cancel()
        continuation.finish()
        return response ?? v2Error(
            id: request.id?.foundationObject,
            code: "request_error",
            message: "Request failed before returning a result"
        )
    }

    /// Applies one deadline to the complete cloud rename transaction. The
    /// provider can perform several refreshes, compare-and-set writes, retries,
    /// and compensation writes, so a per-command timeout alone does not bound
    /// the socket request. The operation task is cancelled when the deadline
    /// wins; the provider's next cancellation check or command boundary then
    /// stops further writes, while the canonical graph remains the authority
    /// for any command that was already in flight.
    private nonisolated func socketCloudRenameResponseWithDeadline(
        id: JSONValue?,
        operation: @escaping @Sendable () async -> String
    ) async -> String {
        let (responses, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let operationTask = Task {
            let response = await operation()
            continuation.yield(response)
            continuation.finish()
        }
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(for: .seconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            continuation.yield(Self.v2Encoder.error(
                id: id,
                code: "timeout",
                message: String(
                    localized: "socket.vm.renameTimedOut",
                    defaultValue: "The remote rename timed out after 120 seconds. Refresh and try again."
                )
            ))
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in
            operationTask.cancel()
            timeoutTask.cancel()
        }

        let response = await withTaskCancellationHandler(
            operation: {
                var iterator = responses.makeAsyncIterator()
                return await iterator.next()
            },
            onCancel: {
                operationTask.cancel()
                timeoutTask.cancel()
                continuation.finish()
            }
        )
        operationTask.cancel()
        timeoutTask.cancel()
        continuation.finish()
        return response ?? Self.v2Encoder.error(
            id: id,
            code: "request_error",
            message: "Request failed before returning a result"
        )
    }

    private nonisolated func processParsedV2CommandAsync(
        _ request: ControlRequest
    ) async throws -> String {
        if let focusError = Self.focusSuppressionResponse(
            method: request.method,
            id: request.id.map(\.foundationObject),
            params: request.params.mapValues(\.foundationObject)
        ) {
            return focusError
        }
        let bridgedParams = request.params.mapValues(\.foundationObject)
        let method = request.method
        let id = request.id?.foundationObject
        if let workspaceParamError = v2UnsupportedWorkspaceAliasError(
            method: method,
            params: bridgedParams
        ) {
            return v2Result(id: id, workspaceParamError)
        }

        let diffViewerRegistration: DiffViewerSessionPreparation = method == "browser.open_split"
            ? v2PrepareDiffViewerRegistration(params: bridgedParams)
            : .notNeeded
        let outcome = try await v2MainAsync {
            let mainParams = request.params.mapValues(\.foundationObject)
            let mainID = request.id?.foundationObject
            return self.v2MainActorResponse(
                request: request,
                id: mainID,
                method: method,
                params: mainParams,
                diffViewerRegistration: diffViewerRegistration
            )
        }
        Task { @MainActor [weak self] in
            self?.scheduleSocketReadSnapshotRefresh()
        }
        switch outcome {
        case .callResult(let result):
            return Self.v2Encoder.response(id: request.id, result)
        case .encoded(let response):
            return response
        }
    }

    private nonisolated static func socketPollingMethod(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            guard case .success(let request) = v2Parser.request(fromLine: trimmed) else {
                return nil
            }
            return request.method
        }
        return trimmed.split(separator: " ", maxSplits: 1)
            .first
            .map { String($0).lowercased() }
    }

    private nonisolated static func snapshotMaximumAgeNanoseconds(
        for method: String
    ) -> UInt64? {
        switch method {
        case "surface.read_text":
            return 100_000_000
        case "system.top":
            return 500_000_000
        case "system.memory":
            return 2_000_000_000
        default:
            return nil
        }
    }

    private nonisolated static func socketRateLimitedResponse(
        command: String,
        retryAfterMilliseconds: Int
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           case .success(let request) = v2Parser.request(fromLine: trimmed) {
            return v2Encoder.error(
                id: request.id,
                code: "rate_limited",
                message: "Polling rate limited for this connection",
                data: .object([
                    "retry_after_ms": .int(Int64(retryAfterMilliseconds)),
                ])
            )
        }
        return "ERROR: rate_limited retry_after_ms=\(retryAfterMilliseconds)"
    }
}
