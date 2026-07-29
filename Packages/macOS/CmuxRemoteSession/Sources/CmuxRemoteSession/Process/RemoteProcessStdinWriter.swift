internal import CmuxFoundation
internal import Foundation

struct RemoteProcessStdinWriter: RemoteProcessStdinWriting {
    func write(
        _ data: Data,
        to handle: FileHandle
    ) throws {
        try handle.writeProcessPipeInput(data)
    }
}
