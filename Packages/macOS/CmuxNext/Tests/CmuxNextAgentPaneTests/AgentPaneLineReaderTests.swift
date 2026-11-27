import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The ready-line reader reads its pipe with `readReady()` (cmuxterm-hq#4753): a chunk is kept until
/// the newline, and the end of the pipe before one is `endOfFile`, as an empty `availableData` was.
struct AgentPaneLineReaderTests {
    @Test func theFirstLineComesBackAcrossChunks() async throws {
        let pipe = Pipe()
        let reader = AgentPaneLineReader(handle: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data(#"{"ready":"#.utf8))
        async let line = reader.firstLine()
        try pipe.fileHandleForWriting.write(contentsOf: Data("true}\nlater\n".utf8))
        #expect(try await line == #"{"ready":true}"#)
        try pipe.fileHandleForWriting.close()
    }

    @Test func theEndOfThePipeBeforeANewlineIsEndOfFile() async throws {
        let pipe = Pipe()
        let reader = AgentPaneLineReader(handle: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("partial".utf8))
        try pipe.fileHandleForWriting.close()
        await #expect(throws: AgentPaneLineReader.Failure.endOfFile) { try await reader.firstLine() }
    }
}
