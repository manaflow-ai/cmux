import Foundation
@testable import CmuxRemoteSession

struct DelayedFailingRemoteProcessStdinWriter: RemoteProcessStdinWriting {
    func write(
        _ data: Data,
        to handle: FileHandle,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws {
        Thread.sleep(forTimeInterval: 0.1)
        throw POSIXError(.EIO)
    }
}
