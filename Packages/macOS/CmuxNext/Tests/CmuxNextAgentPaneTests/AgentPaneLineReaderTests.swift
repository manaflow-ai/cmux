import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneLineReaderTests {
    @Test func returnsTheFirstLineAcrossChunks() async throws {
        let pipe = Pipe()
        let reader = AgentPaneLineReader(handle: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data(#"{"ready":"#.utf8))
        try pipe.fileHandleForWriting.write(contentsOf: Data("true}\nnext\n".utf8))
        #expect(try await reader.firstLine() == #"{"ready":true}"#)
    }

    @Test func endOfFileBeforeANewlineThrows() async throws {
        let pipe = Pipe()
        let reader = AgentPaneLineReader(handle: pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("partial".utf8))
        try pipe.fileHandleForWriting.close()
        await #expect(throws: AgentPaneLineReader.Failure.endOfFile) { try await reader.firstLine() }
    }

    @Test func aDeadlineCancelsTheRead() async throws {
        let pipe = Pipe()
        let reader = AgentPaneLineReader(handle: pipe.fileHandleForReading)
        await #expect(throws: AgentPaneDeadlineExceeded.self) {
            try await withAgentPaneDeadline(.milliseconds(100), label: "test") { try await reader.firstLine() }
        }
        try pipe.fileHandleForWriting.close()
    }
}
