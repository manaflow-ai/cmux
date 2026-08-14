import CmuxRemoteWorkspace
import Dispatch
@testable import CmuxRemoteSession

final class BlockingInheritedMasterReapRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    let exitStarts: AsyncStream<Void>
    let exitFinishes: AsyncStream<Void>

    private let exitStartContinuation: AsyncStream<Void>.Continuation
    private let exitFinishContinuation: AsyncStream<Void>.Continuation
    private let exitGate = DispatchSemaphore(value: 0)

    init() {
        (exitStarts, exitStartContinuation) = AsyncStream.makeStream()
        (exitFinishes, exitFinishContinuation) = AsyncStream.makeStream()
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        if Self.isControlCommand("forward", in: request.arguments) {
            return RemoteCommandResult(
                status: 255,
                stdout: "",
                stderr:
                    "remote port forwarding failed for listen port 64044"
            )
        }
        if Self.isControlCommand("exit", in: request.arguments) {
            exitStartContinuation.yield()
            exitGate.wait()
            exitFinishContinuation.yield()
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }

    func finishExit() {
        exitGate.signal()
    }

    private static func isControlCommand(
        _ command: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.dropLast().contains(where: {
            arguments[$0] == "-O" && arguments[$0 + 1] == command
        })
    }
}
