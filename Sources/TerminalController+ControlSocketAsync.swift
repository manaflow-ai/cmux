import CmuxControlSocket
import Foundation
import os

/// Async socket-dispatch helpers kept separate from the legacy synchronous
/// dispatcher. Socket connections use these methods; in-process callers retain
/// the synchronous `handleSocketLine` contract.

/// Owns the one-shot continuation and the two unstructured tasks used by an
/// async socket deadline. The lock is deliberately limited to the synchronous
/// exactly-once handoff; no mutable domain state is held across an `await`.
private final class V2AsyncResultWaiter: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<String, Never>?
        var pendingResponse: String?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var isFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(
        continuation: CheckedContinuation<String, Never>,
        operation: @escaping @Sendable () async -> String,
        timeoutNanoseconds: UInt64,
        timeoutResponse: String
    ) {
        var responseIfAlreadyFinished: String?
        state.withLock { state in
            if state.isFinished {
                responseIfAlreadyFinished = state.pendingResponse
                state.pendingResponse = nil
            } else {
                state.continuation = continuation
            }
        }
        if let responseIfAlreadyFinished {
            continuation.resume(returning: responseIfAlreadyFinished)
            return
        }

        let operationTask = Task { [weak self] in
            let response = await operation()
            self?.finish(response)
        }
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.finish(timeoutResponse)
        }
        state.withLock { state in
            if state.isFinished {
                operationTask.cancel()
                timeoutTask.cancel()
            } else {
                state.operationTask = operationTask
                state.timeoutTask = timeoutTask
            }
        }
    }

    func finish(_ response: String) {
        var continuation: CheckedContinuation<String, Never>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        state.withLock { state in
            guard !state.isFinished else { return }
            state.isFinished = true
            continuation = state.continuation
            state.continuation = nil
            state.pendingResponse = continuation == nil ? response : nil
            operationTask = state.operationTask
            timeoutTask = state.timeoutTask
            state.operationTask = nil
            state.timeoutTask = nil
        }
        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: response)
    }
}

extension TerminalController {
    /// Runs one long-lived worker operation without blocking a socket
    /// connection thread on a semaphore. The operation and deadline run as
    /// cancellable unstructured tasks; the one-shot waiter returns at the
    /// deadline even if a legacy worker ignores cancellation.
    nonisolated func v2AsyncResultCallAsync(
        id: Any?,
        timeoutSeconds: TimeInterval,
        _ work: @escaping @Sendable () async -> String
    ) async -> String {
        let safeTimeout: TimeInterval
        if timeoutSeconds.isNaN || timeoutSeconds <= 0 {
            safeTimeout = 0
        } else if timeoutSeconds.isFinite {
            // Cap at whole seconds representable by UInt64 nanoseconds; using
            // the floored integer avoids a Double-rounding overflow at max.
            let maximumTimeoutSeconds = Double(UInt64.max / 1_000_000_000)
            safeTimeout = min(timeoutSeconds, maximumTimeoutSeconds)
        } else {
            safeTimeout = Double(UInt64.max / 1_000_000_000)
        }
        let timeoutNanoseconds = UInt64(safeTimeout * 1_000_000_000)
        let displayTimeoutSeconds = Int(min(safeTimeout, Double(Int.max)))
        let timeoutResponse = v2Error(
            id: id,
            code: "timeout",
            message: "Request timed out after \(displayTimeoutSeconds) seconds"
        )
        let cancelledResponse = v2Error(
            id: id,
            code: "cancelled",
            message: "Request was cancelled"
        )
        let waiter = V2AsyncResultWaiter()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                waiter.start(
                    continuation: continuation,
                    operation: work,
                    timeoutNanoseconds: timeoutNanoseconds,
                    timeoutResponse: timeoutResponse
                )
            }
        }, onCancel: {
            waiter.finish(cancelledResponse)
        })
    }

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
    /// main-actor action is awaited.
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

            let relayAuthorization = authorizeRemoteRelayRequest(request)
            if let errorResponse = relayAuthorization.errorResponse {
                return errorResponse
            }
            let authorizedRequest = relayAuthorization.request
            let policy = Self.executionPolicy(forV2Method: authorizedRequest.method)
            return await withSocketCommandPolicyAsync(
                commandKey: authorizedRequest.method,
                isV2: true,
                params: authorizedRequest.params
            ) {
                if policy.runsOnSocketWorker {
                    return await self.socketWorkerV2ResponseAsync(authorizedRequest)
                }
                return await self.processParsedV2CommandAsync(authorizedRequest)
            }
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let commandToken = parts.first else {
            return await v2MainAsync {
                self.processCommand(command)
            }
        }
        let commandName = commandToken.lowercased()
        let args = parts.count > 1 ? parts[1] : ""
        let policy = ControlCommandExecutionPolicy(forV1Command: commandName)
        return await withSocketCommandPolicyAsync(
            commandKey: commandName,
            isV2: false,
            params: commandName == "right_sidebar"
                ? ["args": .string(args)]
                : [:]
        ) {
            if policy.runsOnSocketWorker {
                // The existing worker implementation is already nonisolated
                // for telemetry/diagnostic/remote work. It remains serial
                // within this connection task, preserving v1 FIFO semantics.
                let worker = self.socketWorkerV1ResponseIfHandled(
                    cmd: commandName,
                    args: args
                )
                if worker.handled { return worker.response }
            }
            return await self.v2MainAsync {
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
    ) async -> String? {
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

        if ControlCommandExecutionPolicy.servesFromPublishedReadSnapshot(method: request.method),
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
           let coordinatorResult = await v2MainAsync({
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
            let response = await v2MainAsync {
                self.socketWorkerV2Response(handling: request)
            }
            Task { @MainActor [weak self] in
                self?.scheduleSocketReadSnapshotRefresh()
            }
            return response
        }

        if request.method == "system.top" {
            let response = await v2SystemTopAsync(request)
            if let result = Self.controlCallResult(fromEncodedResponse: response) {
                socketReadSnapshotStore.publishResponse(
                    method: request.method,
                    params: request.params,
                    result: result
                )
            }
            return response
        }

        if request.method == "system.memory" || request.method == "surface.read_text" {
            // These legacy bodies still return Foundation-shaped values. Run
            // the miss on the main actor only when no published snapshot exists;
            // steady-state polling takes the branch above and never enters
            // this fallback.
            let response = await v2MainAsync {
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

        if request.method.hasPrefix("subrouter.") {
            // Subrouter status/accounts/usage/sessions/switch/reload all
            // await network or subprocess work. Keep them on this async
            // connection task instead of falling through to the legacy
            // semaphore-backed synchronous worker response.
            return await socketWorkerSubrouterResponseAsync(
                method: request.method,
                id: request.id,
                params: request.params
            )
        }

        return socketWorkerV2Response(handling: request)
    }

    private nonisolated func v2SystemTopAsync(_ request: ControlRequest) async -> String {
        let base = await v2MainAsync {
            let foundationParams = request.params.mapValues(\.foundationObject)
            return Self.controlCallResult(
                fromLegacy: self.v2SystemTopBasePayload(params: foundationParams)
            )
        }
        guard case .ok(let basePayload) = base,
              case .object(let baseObject) = basePayload,
              case .bool(let includeProcesses)? = baseObject["include_processes"],
              case .array(let rawWindows)? = baseObject["windows"] else {
            return Self.v2Encoder.response(id: request.id, base)
        }
        guard let windowsObject = JSONValue.array(rawWindows).foundationObject as? [[String: Any]] else {
            return Self.v2Encoder.error(
                id: request.id,
                code: "internal_error",
                message: "Invalid system.top payload"
            )
        }

        let processSnapshot = CmuxTopProcessSnapshot.capture(
            includeProcessDetails: includeProcesses
        )
        var windows = windowsObject
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windows)
        let totalPIDs = v2AnnotateTopWindows(
            &windows,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: includeProcesses
        )
        let aggregates = processAggregates(
            from: processSnapshot,
            totalPIDs: totalPIDs
        )
        let memoryDiagnostic = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windows
        )

        var payload = baseObject
        payload["sample"] = JSONValue(
            foundationObject: processSnapshot.samplePayload()
        ) ?? .object([:])
        payload["totals"] = JSONValue(
            foundationObject: processSnapshot.summaryPayload(for: totalPIDs)
        ) ?? .object([:])
        payload["memory_diagnostic"] = JSONValue(
            foundationObject: memoryDiagnostic
        ) ?? .object([:])
        payload["program_totals"] = JSONValue(
            foundationObject: aggregates.programs
        ) ?? .array([])
        payload["coding_agents"] = JSONValue(
            foundationObject: aggregates.codingAgents
        ) ?? .array([])
        payload["windows"] = JSONValue(
            foundationObject: windows
        ) ?? .array([])
        return Self.v2Encoder.response(
            id: request.id,
            .ok(.object(payload))
        )
    }

    private nonisolated func processParsedV2CommandAsync(
        _ request: ControlRequest
    ) async -> String {
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
        let outcome = await v2MainAsync {
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

    /// Async main-actor hop used only by socket tasks. Unlike `v2MainSync`, it
    /// suspends the caller and never parks an I/O thread behind the run loop.
    nonisolated func v2MainAsync<T: Sendable>(
        _ body: @escaping @MainActor @Sendable () -> T
    ) async -> T {
        let policyStack = Self.currentSocketCommandFocusAllowanceStack()
        return await MainActor.run {
            Self.withSocketCommandPolicyStack(policyStack) {
                body()
            }
        }
    }

    /// Applies the focus/command policy across an async socket operation. The
    /// stack is captured by ``v2MainAsync`` before its suspension, so the main
    /// actor observes the same focus allowance as the legacy synchronous lane.
    nonisolated func withSocketCommandPolicyAsync<T: Sendable>(
        commandKey: String,
        isV2: Bool,
        params: [String: JSONValue] = [:],
        _ body: @escaping @Sendable () async -> T
    ) async -> T {
        let foundationParams = params.mapValues(\.foundationObject)
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(
            commandKey: commandKey,
            isV2: isV2,
            params: foundationParams
        )
        var stack = Self.currentSocketCommandFocusAllowanceStack()
        stack.append(allowsFocusMutation)
        Self.setCurrentSocketCommandFocusAllowanceStack(stack)
        defer {
            var restored = Self.currentSocketCommandFocusAllowanceStack()
            if !restored.isEmpty { _ = restored.popLast() }
            Self.setCurrentSocketCommandFocusAllowanceStack(restored)
        }
        return await body()
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

    private nonisolated static func controlCallResult(
        fromEncodedResponse response: String
    ) -> ControlCallResult? {
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else {
            return nil
        }
        if ok {
            guard let rawResult = object["result"],
                  let result = JSONValue(foundationObject: rawResult) else {
                return nil
            }
            return .ok(result)
        }
        guard let error = object["error"] as? [String: Any],
              let code = error["code"] as? String,
              let message = error["message"] as? String else {
            return nil
        }
        return .err(
            code: code,
            message: message,
            data: error["data"].flatMap(JSONValue.init(foundationObject:))
        )
    }

    private nonisolated static func controlCallResult(
        fromLegacy result: V2CallResult
    ) -> ControlCallResult {
        switch result {
        case .ok(let payload):
            guard let value = JSONValue(foundationObject: payload) else {
                return .err(
                    code: "encode_error",
                    message: "Failed to encode JSON",
                    data: nil
                )
            }
            return .ok(value)
        case .err(let code, let message, let data):
            return .err(
                code: code,
                message: message,
                data: data.flatMap(JSONValue.init(foundationObject:))
            )
        }
    }
}
