import CmuxFoundation
import Foundation

final class CmuxExtensionPipeOutputCollector: @unchecked Sendable {
    private struct ReadHandle: @unchecked Sendable {
        let fileHandle: FileHandle
    }

    private let readTask: Task<Data, Never>

    init(fileHandle: FileHandle) {
        let readHandle = ReadHandle(fileHandle: fileHandle)
        readTask = Task.detached(priority: .utility) {
            let data = readHandle.fileHandle.readDataToEndOfFileOrEmpty()
            try? readHandle.fileHandle.close()
            return data
        }
    }

    func finish() async -> Data {
        await readTask.value
    }
}
