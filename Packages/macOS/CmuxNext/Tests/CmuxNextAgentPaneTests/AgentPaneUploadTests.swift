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
        // The chunk's base64 stays text: the main thread never decodes it.
        let chunk = AgentPaneRequest(body: ["method": "chat.upload.chunk", "params": ["token": "t", "offset": 0, "data": Data([1, 2]).base64EncodedString()]])
        #expect(chunk == .uploadStage(.chunk(token: "t", offset: 0, base64: Data([1, 2]).base64EncodedString())))
        let largest = Data(repeating: 0, count: 512 * 1024).base64EncodedString()
        #expect(AgentPaneRequest(body: ["method": "chat.upload.chunk", "params": ["token": "t", "offset": 0, "data": largest]]) == .uploadStage(.chunk(token: "t", offset: 0, base64: largest)))
        let oversized = Data(repeating: 0, count: 512 * 1024 + 1).base64EncodedString()
        for data in [oversized, "", "AAA", "AAAAA"] {
            #expect(AgentPaneRequest(body: ["method": "chat.upload.chunk", "params": ["token": "t", "offset": 0, "data": data]]) == .unsupported("chat.upload.chunk"))
        }
    }

    /// A file has no size cap (Leo, 2026-10-24: "I thought we removed the file size limit attachment
    /// situation... we shouldn't have this limit"): a 3 GiB video, and a batch that holds one, start
    /// streaming; the machine they go to refuses one only when its disk lacks room.
    @Test func aFilePastOneGibibyteStartsStreaming() {
        let size = 3 * 1024 * 1024 * 1024
        let begin = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "movie.mov", "size": size]])
        #expect(begin == .uploadStage(.begin(name: "movie.mov", size: size, batchToken: nil, batch: nil)))
        let batch: [[String: Any]] = [["name": "movie.mov", "size": size], ["name": "notes.txt", "size": 2]]
        let first = AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "movie.mov", "size": size, "batch": batch]])
        #expect(first == .uploadStage(.begin(name: "movie.mov", size: size, batchToken: nil,
                                             batch: [AgentPaneUploadBatchEntry(name: "movie.mov", size: size), AgentPaneUploadBatchEntry(name: "notes.txt", size: 2)])))
        #expect(AgentPaneRequest(body: ["method": "chat.upload.begin", "params": ["name": "movie.mov", "size": -1]]) == .unsupported("chat.upload.begin"))
    }

    @Test func aChunksLengthIsReadFromItsTextAlone() {
        for count in [0, 1, 2, 3, 4, 512 * 1024] {
            #expect(AgentPaneUploadStageRequest.decodedLength(Data(repeating: 7, count: count).base64EncodedString()) == count, "\(count)")
        }
        #expect(AgentPaneUploadStageRequest.decodedLength("abc") == nil)
    }
}
