import CmuxFoundation
import Foundation
import Testing

struct ProcessMemoryDiagnosticsTests {
    @Test func ranksAreBoundedAndPrivate() throws {
        let workspaceIDs = (0..<1_000).map { _ in UUID() }
        let samples = workspaceIDs.enumerated().map { index, id in
            ProcessMemorySample(
                name: "private-project", residentBytes: Int64(index + 1),
                physicalFootprintBytes: Int64(index + 1), workspaceID: id
            )
        }
        let result = ProcessMemoryDiagnostics(
            descendants: samples, enumerationComplete: true, enumerationMissingCount: 0
        )
        #expect(result.childRSSBytes == 500_500)
        #expect(result.workspaceRSSBytesByRank == [1_000, 999, 998, 997, 996])
        #expect(result.familyRSSBytes == ["other": 500_500])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: result.payload()), as: UTF8.self)
        #expect(!json.contains("private-project"))
        #expect(workspaceIDs.allSatisfy { !json.contains($0.uuidString) })
    }

    @Test func unavailableCountersDifferFromZeroAndRSSFallback() {
        let result = ProcessMemoryDiagnostics(
            descendants: [
                ProcessMemorySample(name: "node", residentBytes: 100, physicalFootprintBytes: nil, workspaceID: nil),
                ProcessMemorySample(name: "node", residentBytes: nil, physicalFootprintBytes: nil, workspaceID: nil),
                ProcessMemorySample(name: "codex", residentBytes: 0, physicalFootprintBytes: 0, workspaceID: nil)
            ],
            enumerationComplete: false, enumerationMissingCount: 2
        )
        #expect(result.descendantCount == 3)
        #expect(result.childAccountedBytes == 100)
        #expect(result.footprintFallbackCount == 1)
        #expect(result.missingMemoryCount == 1)
        #expect(result.missingRSSCount == 1)
        #expect(!result.enumerationComplete)
        #expect(result.enumerationMissingCount == 2)
    }

    @Test func totalsSaturateAndRejectNegativeMeasurements() {
        let samples = [Int64.max, 1, -1].map {
            ProcessMemorySample(name: "node", residentBytes: $0, physicalFootprintBytes: $0, workspaceID: nil)
        }
        let result = ProcessMemoryDiagnostics(
            descendants: samples, enumerationComplete: true, enumerationMissingCount: 0
        )
        #expect(result.childRSSBytes == Int64.max)
        #expect(result.childAccountedBytes == Int64.max)
        #expect(result.familyRSSBytes["javascript_runtime"] == Int64.max)
    }
}
