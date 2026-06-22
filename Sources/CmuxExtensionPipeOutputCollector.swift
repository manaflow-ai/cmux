import CmuxFoundation
import Foundation

/// Immutable handle around a detached pipe-drain task.
final class CmuxExtensionPipeOutputCollector: Sendable {
    private let readTask: Task<Data, Never>

    init(fileHandle: FileHandle) {
        let fileDescriptor = fileHandle.fileDescriptor
        readTask = Task.detached(priority: .utility) {
            ProcessPipeEndRead.reading(fileDescriptor: fileDescriptor).data
        }
    }

    func finish() async -> Data {
        await readTask.value
    }
}
