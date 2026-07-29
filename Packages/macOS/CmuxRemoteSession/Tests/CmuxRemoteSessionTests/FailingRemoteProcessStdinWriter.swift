import Foundation
@testable import CmuxRemoteSession

struct FailingRemoteProcessStdinWriter: RemoteProcessStdinWriting {
    func write(
        _ data: Data,
        to handle: FileHandle
    ) throws {
        throw POSIXError(.EIO)
    }
}
