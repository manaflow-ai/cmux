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
}
