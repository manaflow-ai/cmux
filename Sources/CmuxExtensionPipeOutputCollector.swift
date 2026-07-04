import CmuxFoundation
import Darwin
import Foundation

/// Immutable handle around a detached pipe-drain task.
final class CmuxExtensionPipeOutputCollector: Sendable {
    private let readTask: Task<Data, Never>

    init(fileHandle: FileHandle) {
        let sourceDescriptor = fileHandle.fileDescriptor
        let fileDescriptor = dup(sourceDescriptor)
        guard fileDescriptor >= 0 else {
            let message = "Could not duplicate process pipe fd \(sourceDescriptor): \(String(cString: strerror(errno)))"
            readTask = Task.detached(priority: .utility) {
                Data(message.utf8)
            }
            return
        }

        readTask = Task.detached(priority: .utility) {
            defer { Darwin.close(fileDescriptor) }
            ProcessPipeEndRead.reading(fileDescriptor: fileDescriptor).data
        }
    }

    func finish() async -> Data {
        await readTask.value
    }
}
