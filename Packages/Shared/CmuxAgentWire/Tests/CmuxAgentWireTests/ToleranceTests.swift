import Foundation
import Testing
import CmuxAgentReplica
@testable import CmuxAgentWire

@Suite struct ToleranceTests {
    @Test func entriesDropsOnlyMalformedElementsAndReportsCount() throws {
        let json = #"{"entries":[\#(WireTestSupport.entryJSON),{"journal_id":"journal-1","seq":"bad"}],"has_more_before":false,"journal_id":"journal-1","tail_seq":10,"window_end":10,"window_start":10}"#
        let decoded = try JSONDecoder().decode(GuiEntriesResult.self, from: Data(json.utf8))

        #expect(decoded.entries == [WireTestSupport.entry])
        #expect(decoded.malformedEntryCount == 1)
        #expect(decoded.tailSeq == EntrySeq(rawValue: 10))
    }

    @Test func streamTickDecodeTruncatesTextTailToSixteenKilobytes() throws {
        let oversized = String(repeating: "x", count: GuiStreamTickEvent.textTailByteLimit + 512)
        let json = #"{"after_seq":10,"journal_id":"journal-1","revision":3,"text_tail":"\#(oversized)"}"#
        let decoded = try JSONDecoder().decode(GuiStreamTickEvent.self, from: Data(json.utf8))

        #expect(decoded.textTail.utf8.count == GuiStreamTickEvent.textTailByteLimit)
        #expect(decoded.textTail == String(repeating: "x", count: GuiStreamTickEvent.textTailByteLimit))
    }

    @Test func streamTickTruncationPreservesValidUTF8Tail() throws {
        let oversized = "😀" + String(repeating: "x", count: GuiStreamTickEvent.textTailByteLimit - 2)
        let json = #"{"after_seq":10,"journal_id":"journal-1","revision":3,"text_tail":"\#(oversized)"}"#
        let decoded = try JSONDecoder().decode(GuiStreamTickEvent.self, from: Data(json.utf8))

        #expect(decoded.textTail == String(repeating: "x", count: GuiStreamTickEvent.textTailByteLimit - 2))
        #expect(decoded.textTail.utf8.count <= GuiStreamTickEvent.textTailByteLimit)
    }
}
