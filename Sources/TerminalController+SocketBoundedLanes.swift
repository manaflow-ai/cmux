import CmuxControlSocket
import Foundation

/// A socket command's hop onto the main actor exceeded its deadline.
struct SocketMainActorHopTimeout: Error {
    /// `true` when the hop was withdrawn before its body ran, so the command
    /// had no effect and the client may retry it.
    let retryable: Bool
}

/// State a socket command task carries across its suspensions. The
/// connection task, not the thread it happens to resume on, owns it: a task
/// may continue on any thread after an `await`, so the thread-local stack the
/// synchronous lanes read is only ever written inside a lane body, from here.
enum SocketCommandTaskPolicy {
    /// The focus-allowance stack of the enclosing
    /// ``TerminalController/withSocketCommandPolicyAsync(commandKey:isV2:params:_:)``
    /// scopes, innermost last.
    @TaskLocal static var focusAllowanceStack: [Bool] = []
}

/// The two execution lanes a socket connection task may hop onto, each kept
/// from parking the task (or a cooperative-pool thread) forever:
///
/// - The **main-actor lane** runs command bodies through a
///   ``ControlBoundedHop`` with a deadline. A stalled main thread (a nested
///   modal run loop, a long synchronous turn) turns into a structured
///   `timeout` reply after ``TerminalController/socketMainActorHopDeadlineMilliseconds``
///   instead of an orphaned connection, and a withdrawn body never runs late.
/// - The **blocking worker lane** runs the legacy synchronous worker bodies
///   (which may block in `v2MainSync`) on GCD threads rather than on the
///   Swift cooperative pool, so a main-actor stall can no longer exhaust the
///   cooperative pool and freeze every other task in the process.
///
/// Both are the fix for <https://github.com/manaflow-ai/cmux/issues/13369>.
extension TerminalController {
    /// Deadline for one socket command's main-actor hop (queue wait plus
    /// body). Above the hang detector's 8 s stall threshold so a hang sample
    /// is captured first, below the CLI's 15 s response timeout so the client
    /// receives this reply rather than its own timeout.
    nonisolated static let socketMainActorHopDeadlineMilliseconds = 10_000

    /// Connection jobs that may run at once.
    nonisolated static let socketClientMaximumConcurrentJobs = 32
    /// Connection jobs that may wait for a slot.
    nonisolated static let socketClientMaximumPendingJobs = 64
    /// Unauthenticated peers that may be read concurrently.
    nonisolated static let socketClientPreauthorizationMaximumClaims = 32
    /// Rejections the overload responder answers concurrently: everything the
    /// pool can reject in one burst (a batch expiry of the whole pending
    /// queue, or a stop that drops it) plus the preauthorization limiter's
    /// denials, with headroom for the accept buffer, so a burst never falls
    /// back to a bare close (#13397 review).
    nonisolated static let socketOverloadMaximumConcurrentReplies =
        socketClientMaximumConcurrentJobs + socketClientMaximumPendingJobs
        + socketClientPreauthorizationMaximumClaims + 128

    /// Longest an accepted connection may wait for a pool slot. Matches the
    /// CLI's default response timeout: a job older than this belongs to a
    /// client that has already given up, so running it would only apply
    /// stale side effects.
    nonisolated static let socketPendingConnectionMaximumAgeNanoseconds: UInt64 = 15_000_000_000

    private nonisolated static let socketMainActorHop = ControlBoundedHop(
        deadlineMilliseconds: socketMainActorHopDeadlineMilliseconds
    )

    /// Legacy synchronous worker bodies may block in `DispatchQueue.main.sync`
    /// (`v2MainSync`) and in semaphore bridges. They run here, on GCD threads
    /// the system grows on demand, so they never block a Swift
    /// cooperative-pool thread. This is the sanctioned legacy blocking
    /// boundary, not general async work.
    private nonisolated static let socketBlockingWorkerQueue = DispatchQueue(
        label: "com.cmux.socket.blocking-worker",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Async main-actor hop used only by socket tasks. It suspends the caller,
    /// never parks an I/O thread behind the run loop, and gives up after the
    /// hop deadline. The body runs under the command task's focus policy.
    ///
    /// - Throws: ``SocketMainActorHopTimeout`` when the deadline elapses;
    ///   `CancellationError` when the connection task is cancelled.
    nonisolated func v2MainAsync<T: Sendable>(
        _ body: @escaping @MainActor @Sendable () -> T
    ) async throws -> T {
        let policyStack = SocketCommandTaskPolicy.focusAllowanceStack
        let outcome = await Self.socketMainActorHop.run(
            schedule: { job in
                Task { @MainActor in job() }
            },
            body: {
                MainActor.assumeIsolated {
                    Self.withSocketCommandPolicyStack(policyStack) {
                        body()
                    }
                }
            }
        )
        switch outcome {
        case .completed(let value):
            socketLaneHealth.recordMainHopCompleted()
            return value
        case .abandoned:
            throw SocketMainActorHopTimeout(retryable: true)
        case .timedOutWhileRunning:
            throw SocketMainActorHopTimeout(retryable: false)
        case .cancelled:
            throw CancellationError()
        }
    }

    /// Runs a legacy synchronous worker body on the blocking worker lane and
    /// suspends the connection task until it returns. The command task's
    /// focus policy and the automation task-locals are re-bound on the
    /// worker thread, exactly as they are on the calling task.
    nonisolated func runSocketWorkerBlockingBody<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        let policyStack = SocketCommandTaskPolicy.focusAllowanceStack
        let focusAllowed = CmuxAutomationInvocationContext.focusAllowed
        let eventOrigin = CmuxAutomationInvocationContext.eventOrigin
        return await withCheckedContinuation { continuation in
            Self.socketBlockingWorkerQueue.async {
                let value = Self.withSocketCommandPolicyStack(policyStack) {
                    CmuxAutomationInvocationContext.$focusAllowed.withValue(focusAllowed) {
                        CmuxAutomationInvocationContext.$eventOrigin.withValue(eventOrigin) {
                            body()
                        }
                    }
                }
                continuation.resume(returning: value)
            }
        }
    }

    /// Applies the focus/command policy across an async socket operation. The
    /// decision is bound to the command task for the scope of `body`, so it
    /// survives every suspension, and each lane hop (``v2MainAsync``,
    /// ``runSocketWorkerBlockingBody``) copies it into the thread-local stack
    /// its synchronous body reads. Nothing is written to the calling thread.
    nonisolated func withSocketCommandPolicyAsync<T: Sendable>(
        commandKey: String,
        isV2: Bool,
        params: [String: JSONValue] = [:],
        _ body: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        let foundationParams = params.mapValues(\.foundationObject)
        let allowsFocusMutation = Self.socketCommandAllowsInAppFocusMutations(
            commandKey: commandKey,
            isV2: isV2,
            params: foundationParams
        )
        var stack = SocketCommandTaskPolicy.focusAllowanceStack
        stack.append(allowsFocusMutation)
        return try await SocketCommandTaskPolicy.$focusAllowanceStack.withValue(stack) {
            try await body()
        }
    }

    // MARK: - Timeout replies

    private nonisolated static var socketMainHopTimeoutNotRunMessage: String {
        String(
            localized: "socket.mainActorHop.timeout.notRun",
            defaultValue: "cmux did not respond within 10 seconds, so the command was not run. Retry in a moment."
        )
    }

    private nonisolated static var socketMainHopTimeoutMayHaveRunMessage: String {
        String(
            localized: "socket.mainActorHop.timeout.mayHaveRun",
            defaultValue: "cmux did not respond within 10 seconds after the command started, so its result is unknown. Check the effect before retrying."
        )
    }

    private nonisolated static func socketMainHopTimeoutMessage(retryable: Bool) -> String {
        retryable ? socketMainHopTimeoutNotRunMessage : socketMainHopTimeoutMayHaveRunMessage
    }

    private nonisolated static func socketMainHopTimeoutData(retryable: Bool) -> [String: JSONValue] {
        [
            "retryable": .bool(retryable),
            "deadline_ms": .int(Int64(socketMainActorHopDeadlineMilliseconds)),
            "stage": .string("main_actor"),
        ]
    }

    /// The structured reply for a main-actor hop that timed out, plus the
    /// Release telemetry that makes the stall visible: a breadcrumb per
    /// timeout and one captured warning per stall episode.
    nonisolated func socketMainHopTimeoutResponse(
        id: JSONValue?,
        method: String,
        isV2: Bool,
        error: SocketMainActorHopTimeout
    ) async -> String {
        let poolMetrics = await socketClientWorkerPool.metrics()
        let data: [String: Any] = [
            "method": method,
            "retryable": error.retryable,
            "deadline_ms": Self.socketMainActorHopDeadlineMilliseconds,
            "pool_active": poolMetrics.activeJobs,
            "pool_pending": poolMetrics.pendingJobs,
            "pool_rejected": poolMetrics.rejectedJobs,
            "pool_expired": poolMetrics.expiredJobs,
        ]
        sentryBreadcrumb("socket.command.main_hop.timeout", category: "socket", data: data)
        if socketLaneHealth.recordMainHopTimeout() {
            sentryCaptureWarning(
                "socket.main_actor_lane.stalled",
                category: "socket",
                data: data,
                contextKey: "socket_main_lane"
            )
        }
        let message = Self.socketMainHopTimeoutMessage(retryable: error.retryable)
        guard isV2 else {
            return "ERROR: timeout retryable=\(error.retryable) \(message)"
        }
        return Self.v2Encoder.error(
            id: id,
            code: "timeout",
            message: message,
            data: .object(Self.socketMainHopTimeoutData(retryable: error.retryable))
        )
    }

    /// Runs a throwing async body for the synchronous in-process lane's
    /// `v2AsyncResultCall` bridges and maps its failure precisely: only a
    /// ``SocketMainActorHopTimeout`` becomes the `timeout` result (with the
    /// hop's real `retryable`), cancellation is reported as such, and any
    /// other error keeps its own identity instead of masquerading as a
    /// main-thread stall.
    nonisolated func socketLegacyMainHopBridge(
        _ body: () async throws -> V2CallResult
    ) async -> V2CallResult {
        do {
            return try await body()
        } catch let timeout as SocketMainActorHopTimeout {
            return .err(
                code: "timeout",
                message: Self.socketMainHopTimeoutMessage(retryable: timeout.retryable),
                data: Self.socketMainHopTimeoutData(retryable: timeout.retryable)
                    .mapValues(\.foundationObject)
            )
        } catch is CancellationError {
            return .err(
                code: "cancelled",
                message: String(localized: "socket.request.cancelled", defaultValue: "Request was cancelled"),
                data: nil
            )
        } catch {
            return .err(
                code: "request_error",
                message: String(
                    localized: "socket.request.failedBeforeResult",
                    defaultValue: "Request failed before returning a result"
                ),
                data: nil
            )
        }
    }
}
