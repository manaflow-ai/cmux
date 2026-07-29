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
    // lint:allow lock - guards one counter and the broadcast test gate.
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
