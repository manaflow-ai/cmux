internal import CmuxFoundation
internal import Foundation

protocol RemoteProcessStdinWriting: Sendable {
    func write(
        _ data: Data,
        to handle: FileHandle
    ) throws
}

struct RemoteProcessStdinWriter: RemoteProcessStdinWriting {
    func write(
        _ data: Data,
        to handle: FileHandle
    ) throws {
        try handle.writeProcessPipeInput(data)
    }
}
