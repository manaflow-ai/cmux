import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite("FileHandle process-pipe writing")
struct FileHandleProcessPipeWritingTests {
    @Test("writeProcessPipeInput writes every byte")
    func writesEveryByte() async throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        let payload = Data(repeating: 0x41, count: 128 * 1024)

        let readDescriptor = pipe.fileHandleForReading.fileDescriptor
        let readTask = Task.detached {
            ProcessPipeEndRead.reading(fileDescriptor: readDescriptor)
        }
        try pipe.fileHandleForWriting.writeProcessPipeInput(payload)
        try pipe.fileHandleForWriting.close()

        let result = await readTask.value
        #expect(result.readError == nil)
        #expect(result.data == payload)
    }

    @Test("writeProcessPipeInput reports EPIPE when the reader closes")
    func reportsClosedReader() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        defer { try? pipe.fileHandleForWriting.close() }

        do {
            try pipe.fileHandleForWriting.writeProcessPipeInput(Data("payload".utf8))
            Issue.record("Expected the closed process pipe to reject input")
        } catch let error as POSIXError {
            #expect(error.code == .EPIPE)
        } catch {
            Issue.record("Expected POSIXError, received \(error)")
        }
    }
}
