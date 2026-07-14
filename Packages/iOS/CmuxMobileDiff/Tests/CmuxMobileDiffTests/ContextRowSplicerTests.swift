import Testing

@testable import CmuxMobileDiff

@Suite struct ContextRowSplicerTests {
    @Test func downExpansionKeepsNumberingAndAdvancesGap() throws {
        let gap = DiffExpansionGap(id: "gap", newStart: 5, newEnd: 10, oldLineDelta: -2)
        let plan = try #require(ContextExpansionPlan(gap: gap, direction: .down, chunkSize: 2))
        let rows = [gapRow(gap)]
        let result = ContextRowSplicer().splice(rows: rows, gapID: "gap", plan: plan, texts: ["five", "six"])
        #expect(result[0].newLineNumber == 5)
        #expect(result[0].oldLineNumber == 3)
        #expect(result[1].newLineNumber == 6)
        #expect(result[2].expansionGap?.newStart == 7)
        #expect(result[2].expansionGap?.newEnd == 10)
    }

    @Test func upExpansionInsertsAfterRemainingGap() throws {
        let gap = DiffExpansionGap(id: "gap", newStart: 5, newEnd: 10, oldLineDelta: 1)
        let plan = try #require(ContextExpansionPlan(gap: gap, direction: .up, chunkSize: 2))
        let result = ContextRowSplicer().splice(rows: [gapRow(gap)], gapID: "gap", plan: plan, texts: ["nine", "ten"])
        #expect(result[0].expansionGap?.newEnd == 8)
        #expect(result[1].newLineNumber == 9)
        #expect(result[1].oldLineNumber == 10)
        #expect(result[2].newLineNumber == 10)
    }

    @Test func expandAllRemovesBoundedGap() throws {
        let gap = DiffExpansionGap(id: "gap", newStart: 2, newEnd: 3, oldLineDelta: 0)
        let plan = try #require(ContextExpansionPlan(gap: gap, direction: .all))
        let result = ContextRowSplicer().splice(rows: [gapRow(gap)], gapID: "gap", plan: plan, texts: ["two", "three"])
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.expansionGap == nil })
    }

    @Test func shortEOFResponseExhaustsOpenEndedGap() throws {
        let gap = DiffExpansionGap(id: "eof", newStart: 20, newEnd: nil, oldLineDelta: 3)
        let plan = try #require(ContextExpansionPlan(gap: gap, direction: .down, chunkSize: 4))
        let result = ContextRowSplicer().splice(rows: [gapRow(gap)], gapID: "eof", plan: plan, texts: ["last"])
        #expect(result.count == 1)
        #expect(result[0].newLineNumber == 20)
        #expect(result[0].oldLineNumber == 23)
    }

    private func gapRow(_ gap: DiffExpansionGap) -> DiffRowSnapshot {
        DiffRowSnapshot(id: gap.id, kind: .expansionGap, text: "", expansionGap: gap)
    }
}
