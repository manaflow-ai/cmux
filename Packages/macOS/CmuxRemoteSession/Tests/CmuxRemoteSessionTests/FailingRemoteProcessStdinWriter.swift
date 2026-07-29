import Foundation
@testable import CmuxRemoteSession

struct FailingRemoteProcessStdinWriter: RemoteProcessStdinWriting {
    func write(
        _ data: Data,
        to handle: FileHandle,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws {
        throw POSIXError(.EIO)
    }
}
