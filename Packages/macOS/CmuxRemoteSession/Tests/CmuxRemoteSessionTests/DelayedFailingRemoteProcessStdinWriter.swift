import Foundation
@testable import CmuxRemoteSession

struct DelayedFailingRemoteProcessStdinWriter: RemoteProcessStdinWriting {
    func write(
        _ data: Data,
        to handle: FileHandle
    ) throws {
        Thread.sleep(forTimeInterval: 0.1)
        throw POSIXError(.EIO)
    }
}
