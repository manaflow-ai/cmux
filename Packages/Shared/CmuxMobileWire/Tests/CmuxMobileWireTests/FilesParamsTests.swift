import Foundation
import Testing
@testable import CmuxMobileWire

@Suite struct FilesParamsTests {
    let fixtures = Fixtures()

    private func frames(_ message: String, phase: String = "request") throws -> [JSONValue] {
        try #require(fixtures.json("fixtures/files.json")["cases"]?.arrayValue)
            .filter { ($0["phase"]?.stringValue ?? "request") == phase && $0["message"]?.stringValue == message }
            .compactMap { $0["frame"] }
    }

    @Test func uploadParamsRoundTrip() throws {
        let frame = try #require(frames("files.upload").first)
        let params = try #require(frame["params"]).decode(as: FilesUploadParams.self)
        #expect(params.dest == FilesUploadDestination(kind: .terminal, terminal: "term_t01"))
        #expect(params.size == 2_483_021)
        #expect(try JSONValue(encoding: params) == frame["params"])
        let opened = try #require(frames("files.upload", phase: "opened").first?["params"]).decode(as: FilesUploadOpenedParams.self)
        #expect(opened == FilesUploadOpenedParams(upload: "up_7Hq2", offset: 1_048_576))
    }

    @Test func downloadAndListRoundTrip() throws {
        let download = try #require(frames("files.download").first?["params"])
        #expect(try download.decode(as: FilesDownloadParams.self) == FilesDownloadParams(path: "/Users/me/src/cmux/out.log"))
        let opened = try #require(frames("files.download", phase: "opened").first?["params"])
        #expect(try JSONValue(encoding: opened.decode(as: FilesDownloadOpenedParams.self)) == opened)
        let list = try #require(frames("files.list", phase: "result").first?["value"])
        let result = try list.decode(as: FilesListResult.self)
        #expect(result.entries.map(\.kind) == [.dir, .file])
        #expect(try JSONValue(encoding: result) == list)
        let roots = try #require(frames("files.roots", phase: "result").first?["value"])
        #expect(try roots.decode(as: FilesRootsResult.self).roots.first?.id == "inbox")
    }

    @Test func uploadMessagesDecodeFromFixtures() throws {
        let end = try MobileJSON(value: #require(frames("files.upload.end").first))
        guard case .message(let endMessage) = end, let typed = FilesUploadEnd(endMessage) else {
            Issue.record("files.upload.end did not decode")
            return
        }
        #expect(typed.message.jsonValue == endMessage.jsonValue)
        let done = try MobileJSON(value: #require(frames("files.upload.done").first))
        guard case .message(let doneMessage) = done, let typedDone = FilesUploadDone(doneMessage) else {
            Issue.record("files.upload.done did not decode")
            return
        }
        #expect(typedDone.size == 2_483_021)
        #expect(typedDone.message.jsonValue == doneMessage.jsonValue)
    }
}
