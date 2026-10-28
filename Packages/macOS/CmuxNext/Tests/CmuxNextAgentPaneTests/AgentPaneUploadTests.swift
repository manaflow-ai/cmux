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

    @Test func decodesStagedCloudUploadRequestsAndBoundsChunks() {
        let begin = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "large.bin", "size": 1_000_000]])
        #expect(begin == .uploadStage(.begin(name: "large.bin", size: 1_000_000, batchToken: nil, batch: nil)))
        let chunk = AgentPaneRequest(body: ["method": "chat.upload.chunk", "params": ["token": "t", "offset": 0, "data": Data([1, 2]).base64EncodedString()]])
        #expect(chunk == .uploadStage(.chunk(token: "t", offset: 0, data: Data([1, 2]))))
        let oversized = Data(repeating: 0, count: 512 * 1024 + 1).base64EncodedString()
        #expect(AgentPaneRequest(body: ["method": "chat.upload.chunk", "params": ["token": "t", "offset": 0, "data": oversized]]) == .unsupported("chat.upload.chunk"))
    }

    /// Attachments take arbitrarily large files of any type (Leo, 2026-10-26): a staged upload of
    /// any size begins, alone or in a batch, however much the batch holds. Only the chunk is bounded.
    @Test func aStagedUploadOfAnySizeBegins() {
        let gib = 1024 * 1024 * 1024
        let large = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "disk.img", "size": 2 * gib]])
        #expect(large == .uploadStage(.begin(name: "disk.img", size: 2 * gib, batchToken: nil, batch: nil)))
        let batch: [[String: Any]] = [["name": "a.mov", "size": 600 * 1024 * 1024], ["name": "b.mov", "size": 600 * 1024 * 1024],
                                      ["name": "c.img", "size": 3 * gib]]
        let begin = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "a.mov", "size": 600 * 1024 * 1024, "batch": batch]])
        #expect(begin == .uploadStage(.begin(name: "a.mov", size: 600 * 1024 * 1024, batchToken: nil,
                                             batch: [AgentPaneUploadBatchEntry(name: "a.mov", size: 600 * 1024 * 1024),
                                                     AgentPaneUploadBatchEntry(name: "b.mov", size: 600 * 1024 * 1024),
                                                     AgentPaneUploadBatchEntry(name: "c.img", size: 3 * gib)])))
        #expect(AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "a.bin", "size": -1]]) == .unsupported("chat.upload.begin"))
        let negative: [[String: Any]] = [["name": "a.bin", "size": 1], ["name": "b.bin", "size": -1]]
        #expect(AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "a.bin", "size": 1, "batch": negative]])
            == .unsupported("chat.upload.begin"))
    }
}
