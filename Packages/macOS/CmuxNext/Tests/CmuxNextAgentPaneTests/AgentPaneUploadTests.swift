import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneUploadTests {
    @Test func acceptsMoreThanTenFilesWithinByteAndNameLimits() {
        let files: [[String: Any]] = (0..<11).map { index in
            ["name": "part-\(index).zip", "data": Data([UInt8(index)]).base64EncodedString()]
        }
        let parsed = AgentPaneUpload.files(["files": files])
        #expect(parsed?.count == 11)
    }

    @Test(arguments: [0, 1_073_741_825, Int.max])
    func stagedUploadAcceptsAnyNonnegativeFileSize(size: Int) {
        let entry: [String: Any] = ["name": "large.bin", "size": size]
        let request = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": [
            "name": "large.bin", "size": size, "batch": [entry, entry],
        ]])
        #expect(request == .uploadStage(.begin(name: "large.bin", size: size, batchToken: nil,
                                              batch: [AgentPaneUploadBatchEntry(name: "large.bin", size: size),
                                                      AgentPaneUploadBatchEntry(name: "large.bin", size: size)])))
    }

    @Test func stagedUploadAccepts65LargeFiles() {
        let size = 1_073_741_825
        let entries = (0..<65).map { AgentPaneUploadBatchEntry(name: "part-\($0).bin", size: size) }
        let manifest: [[String: Any]] = entries.map { ["name": $0.name, "size": $0.size] }
        let request = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": [
            "name": "part-0.bin", "size": size, "batch": manifest,
        ]])
        #expect(request == .uploadStage(.begin(name: "part-0.bin", size: size, batchToken: nil, batch: entries)))
    }

    @Test func liveFirstStageRetainsBatchAcrossLongStagingAndTransfer() {
        let now = Date(timeIntervalSince1970: 100)
        let large = AgentPaneUploadBatchEntry(name: "first.bin", size: Int.max)
        let next = AgentPaneUploadBatchEntry(name: "next.bin", size: 1_073_741_825)
        var batch = AgentPaneUploadBatch([large, next], now: now)
        let firstBegan = batch.begin(name: large.name, size: large.size, stage: "first", at: now)
        #expect(firstBegan)
        let staged = now.addingTimeInterval(11 * 60)
        let finished = staged.addingTimeInterval(11 * 60)
        // Advance beyond ten minutes in each phase, using the same ownership as both stagers.
        #expect(batch.isAlive(at: staged))
        #expect(batch.abandonmentDeadline == nil)
        #expect(batch.isAlive(at: finished))
        let unapprovedBegan = batch.begin(name: "unapproved.bin", size: 1, stage: "other", at: finished)
        #expect(!unapprovedBegan)
        batch.release(stage: "first", at: finished)
        let nextBegan = batch.begin(name: next.name, size: next.size, stage: "next", at: finished.addingTimeInterval(1))
        #expect(nextBegan)
        #expect(batch.abandonmentDeadline == nil)
        batch.release(stage: "next", at: finished.addingTimeInterval(2))
        #expect(batch.isComplete)
    }

    @Test func batchAbandonmentStartsAfterLastStageAndCannotBeExtendedByUnknownOwner() {
        let now = Date(timeIntervalSince1970: 100)
        let entry = AgentPaneUploadBatchEntry(name: "file.bin", size: Int.max)
        var batch = AgentPaneUploadBatch([entry, entry, entry], now: now)
        let firstBegan = batch.begin(name: entry.name, size: entry.size, stage: "one", at: now)
        let secondBegan = batch.begin(name: entry.name, size: entry.size, stage: "two", at: now)
        #expect(firstBegan)
        #expect(secondBegan)
        let late = now.addingTimeInterval(22 * 60)
        batch.release(stage: "one", at: late)
        #expect(batch.abandonmentDeadline == nil)
        batch.release(stage: "two", at: late)
        batch.release(stage: "unknown", at: late.addingTimeInterval(9 * 60))
        let thirdBegan = batch.begin(name: entry.name, size: entry.size, stage: "three", at: late.addingTimeInterval(10 * 60))
        #expect(!thirdBegan)
    }

    @Test func stagedUploadRejectsNegativeFileAndBatchSizes() {
        for params: [String: Any] in [["name": "a", "size": -1],
                                     ["name": "a", "size": 0, "batch": [["name": "a", "size": -1]]]] {
            #expect(AgentPaneRequest(body: ["method": "chat.upload.begin", "params": params]) == .unsupported("chat.upload.begin"))
        }
    }

    @Test func decodesStagedCloudUploadRequestsAndBoundsChunks() {
        let begin = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "large.bin", "size": 1_000_000]])
        #expect(begin == .uploadStage(.begin(name: "large.bin", size: 1_000_000, batchToken: nil, batch: nil)))
        let chunk = AgentPaneRequest(body: ["method": "chat.upload.chunk", "params": ["token": "t", "offset": 0, "data": Data([1, 2]).base64EncodedString()]])
        #expect(chunk == .uploadStage(.chunk(token: "t", offset: 0, data: Data([1, 2]))))
        let oversized = Data(repeating: 0, count: 512 * 1024 + 1).base64EncodedString()
        #expect(AgentPaneRequest(body: ["method": "chat.upload.chunk", "params": ["token": "t", "offset": 0, "data": oversized]]) == .unsupported("chat.upload.chunk"))
    }

    /// A pasted screenshot's original goes in chunks on the shared page host too. Without these ops
    /// the page fell back to one `chat.upload` frame with the whole file, which the Chromium bridge
    /// refused past 4 MiB without an answer: the chip stayed a placeholder and Enter waited on it.
    @Test func stagedUploadOpsReachThePaneOnThePageHost() {
        for method in ["chat.upload.begin", "chat.upload.chunk", "chat.upload.finish", "chat.upload.cancel"] {
            #expect(AgentPageOps.method(for: AgentPageOps.namespace + method) == method)
        }
    }
}
