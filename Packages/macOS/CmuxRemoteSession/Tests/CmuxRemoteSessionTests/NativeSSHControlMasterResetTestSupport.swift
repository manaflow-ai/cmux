import CmuxFoundation
import Foundation
@testable import CmuxRemoteSession

final class ResetEventRecorder: @unchecked Sendable {
    // lint:allow lock - event callbacks increment one test counter.
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock {
            value += 1
        }
    }
}

final class RetryThenSuccessResetRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    // lint:allow lock - process calls consume one scripted test counter.
    private let lock = NSLock()
    private let retryCount: Int
    private var count = 0

    init(retryCount: Int) {
        self.retryCount = retryCount
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        let attempt = lock.withLock {
            count += 1
            return count
        }
        if attempt <= retryCount {
            return RemoteCommandResult(
                status: NativeSSHControlMasterCleanupRequest.retryExitStatus,
                stdout: "",
                stderr: "foreground authentication still active"
            )
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}

final class ThrowThenSuccessResetRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    // lint:allow lock - process calls consume one scripted test counter.
    private let lock = NSLock()
    private let throwCount: Int
    private var count = 0

    init(throwCount: Int) {
        self.throwCount = throwCount
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        let attempt = lock.withLock {
            count += 1
            return count
        }
        if attempt <= throwCount {
            throw NSError(
                domain: "NativeSSHControlMasterResetTests",
                code: attempt
            )
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}

final class FixedStatusResetRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    // lint:allow lock - process calls increment one test counter.
    private let lock = NSLock()
    private let status: Int32
    private var count = 0

    init(status: Int32) {
        self.status = status
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock {
            count += 1
        }
        return RemoteCommandResult(
            status: status,
            stdout: "",
            stderr: "cleanup wrapper skipped ssh"
        )
    }
}

final class ResolvingResetRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    // lint:allow lock - process calls append test request snapshots.
    private let lock = NSLock()
    private let pathsByDestination: [String: String]
    private var requests: [RemoteProcessRequest] = []

    init(pathsByDestination: [String: String]) {
        self.pathsByDestination = pathsByDestination
    }

    var exitRequests: [RemoteProcessRequest] {
        lock.withLock {
            requests.filter {
                $0.arguments.contains("-O") && $0.arguments.contains("exit")
            }
        }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock {
            requests.append(request)
        }
        if request.arguments.contains("-G"),
           let destination = request.arguments.last,
           let path = pathsByDestination[destination] {
            return RemoteCommandResult(
                status: 0,
                stdout: "controlpath \(path)\n",
                stderr: ""
            )
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}

final class BlockingResolvingResetRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    let resolutions: AsyncStream<Void>
    let exits: AsyncStream<Void>

    // lint:allow lock - process calls increment one test counter.
    private let lock = NSLock()
    private let resolvedPath: String
    private let resolutionContinuation: AsyncStream<Void>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation
    private let exitRelease = DispatchSemaphore(value: 0)
    private var _exitCount = 0

    init(resolvedPath: String) {
        self.resolvedPath = resolvedPath
        (resolutions, resolutionContinuation) = AsyncStream.makeStream()
        (exits, exitContinuation) = AsyncStream.makeStream()
    }

    var exitCount: Int {
        lock.withLock { _exitCount }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        if request.arguments.contains("-G") {
            resolutionContinuation.yield()
            return RemoteCommandResult(
                status: 0,
                stdout: "controlpath \(resolvedPath)\n",
                stderr: ""
            )
        }
        if request.arguments.contains("-O"),
           request.arguments.contains("exit") {
            lock.withLock {
                _exitCount += 1
            }
            exitContinuation.yield()
            exitRelease.wait()
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }

    func finishExit() {
        exitRelease.signal()
    }
}
