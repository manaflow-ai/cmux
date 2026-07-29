internal import CmuxFoundation
internal import Foundation

protocol RemoteProcessStdinWriting: Sendable {
    func write(
        _ data: Data,
        to handle: FileHandle,
        stopFileDescriptor: Int32
    ) throws
}
