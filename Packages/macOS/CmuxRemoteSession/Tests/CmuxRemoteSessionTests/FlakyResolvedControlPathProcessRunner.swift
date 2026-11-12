import Foundation
@testable import CmuxRemoteSession

final class FlakyResolvedControlPathProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    // lint:allow lock - resolution calls consume one scripted test counter.
    private let lock = NSLock()
    private let base: any RemoteSessionProcessRunning
    private let controlPath: String
    private let failureCount: Int
    private var attempts = 0

    init(
        base: any RemoteSessionProcessRunning,
        failureCount: Int,
        controlPath: String = ResolvedControlPathFixture.path
    ) {
        self.base = base
        self.failureCount = failureCount
        self.controlPath = controlPath
    }

    var resolutionAttempts: Int {
        lock.withLock { attempts }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        if request.executable == "/usr/bin/ssh",
           request.arguments.first == "-G" {
            let attempt = lock.withLock {
                attempts += 1
                return attempts
            }
            guard attempt > failureCount else {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: "temporary configuration failure"
                )
            }
            return RemoteCommandResult(
                status: 0,
                stdout: "controlpath \(controlPath)\n",
                stderr: ""
            )
        }
        return try base.run(request, operation: operation)
    }
}
