import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("TerminalCommandBlock row")
struct TerminalCommandRowTests {
    @Test("each terminal block maps to a distinct, prefixed transcript row id")
    func distinctIDs() {
        let rows = (0..<5).map { id in
            ChatTranscriptRow.terminalCommand(TerminalCommandBlock(id: id, command: "c\(id)"))
        }
        let ids = rows.map(\.id)
        #expect(Set(ids).count == ids.count) // no duplicates -> no ForEach diff thrash
        #expect(ids.allSatisfy { $0.hasPrefix("term-") })
    }

    @Test("a terminal row never collides with message/pending row ids")
    func noCrossKindCollision() {
        let term = ChatTranscriptRow.terminalCommand(TerminalCommandBlock(id: 1, command: "x"))
        #expect(term.id != "msg-1")
        #expect(term.id != "pending-1")
    }

    @Test("blocks differing only in output are not equal (live updates re-render)")
    func outputChangeBreaksEquality() {
        let a = TerminalCommandBlock(id: 0, command: "build", output: "step 1")
        let b = TerminalCommandBlock(id: 0, command: "build", output: "step 1\nstep 2")
        #expect(a != b)
        #expect(ChatTranscriptRow.terminalCommand(a) != ChatTranscriptRow.terminalCommand(b))
    }
}
