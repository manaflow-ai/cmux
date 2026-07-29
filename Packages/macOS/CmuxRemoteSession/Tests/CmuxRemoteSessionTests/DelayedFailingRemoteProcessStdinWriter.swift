import Foundation
@testable import CmuxRemoteSession

struct ExitGatedFailingRemoteProcessStdinWriter: RemoteProcessStdinWriting {
    let processDidExit: DispatchSemaphore

    func write(
        _ data: Data,
        to handle: FileHandle,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws {
        guard processDidExit.wait(timeout: .now() + 2) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        throw POSIXError(.EIO)
    }
}
