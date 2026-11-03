import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneCloudAttachmentsTests {
    private let image: JSONValue = .object([
        "id": .string("screenshot"), "kind": .string("image"), "name": .string("screen.png"),
        "mimeType": .string("image/png"), "size": .number(3), "data": .string("YWJj"),
        "inline": .bool(true), "originalPath": .string("/Users/me/Desktop/screen.png"),
    ])

    @Test func firstSendCopiesImageBytesAndReplacesTheMacReference() async throws {
        let carry = try #require(AgentPaneCloudAttachments([image]))
        let files = try await carry.uploads()
        #expect(files == [AgentPaneUpload(name: "screen.png", data: Data("abc".utf8))])
        let remote = try #require(carry.remapped(["/work/local/uploads/one/screen.png"]))
        #expect(remote[0]["data"] == .string("YWJj"))
        #expect(remote[0]["inline"] == .bool(true))
        #expect(remote[0]["originalPath"] == .string("/work/local/uploads/one/screen.png"))
        #expect(remote[0]["originalName"] == .string("screen.png"))
        #expect(carry.remapped([]) == nil)
    }

    @Test func documentAudioTextAndPastedPayloadsKeepTheirOrder() async throws {
        let kinds = ["document", "audio", "text", "pasted"]
        let chips: [JSONValue] = kinds.enumerated().map { index, kind in
            var chip: [String: JSONValue] = ["id": .string("\(index)"), "kind": .string(kind), "name": .string("file-\(index)"), "mimeType": .string("text/plain"), "size": .number(3)]
            chip[index < 2 ? "data" : "text"] = .string(index < 2 ? "YWJj" : "the words")
            return .object(chip)
        }
        let carry = try #require(AgentPaneCloudAttachments(chips))
        #expect(try await carry.uploads().map(\.name) == ["file-0", "file-1"])
        let remote = try #require(carry.remapped(["/work/0", "/work/1"]))
        #expect(remote.map { $0["id"] } == chips.map { $0["id"] })
        #expect(remote[2]["text"] == .string("the words"))
        #expect(remote[3]["text"] == .string("the words"))
    }

    @Test func pathOnlyFilesFoldersAndMalformedPayloadsCannotReadThisMac() async throws {
        for kind in ["link", "image", "document", "audio", "text"] {
            let chip: JSONValue = .object(["id": .string("file"), "kind": .string(kind), "name": .string("secret"), "path": .string("/Users/me/.ssh/id_ed25519")])
            #expect(AgentPaneCloudAttachments([chip]) == nil)
        }
        let malformed: JSONValue = .object(["id": .string("file"), "kind": .string("image"), "name": .string("../escape"), "data": .string("YWJj")])
        #expect(AgentPaneCloudAttachments([malformed]) == nil)
        var corrupt = try #require(image.objectValue)
        corrupt["data"] = .string("not base64!")
        let carry = try #require(AgentPaneCloudAttachments([.object(corrupt)]))
        await #expect(throws: (any Error).self) { try await carry.uploads() }
    }

    @Test func theFirstCloudPromptRetainsItsAttachments() throws {
        let start = try #require(AgentPaneCloudStart(params: ["task": "", "key": UUID().uuidString, "home": true,
                                                             "attachments": [image.foundationObject]]))
        #expect(start.attachments == [image])
        #expect(start.seed(cwd: nil).promptAttachments == [image])
        #expect(AgentPaneCloudStart(params: ["task": "", "key": UUID().uuidString]) == nil)
        #expect(AgentPaneCloudStart(params: ["task": "look", "key": UUID().uuidString, "attachments": "wrong"]) == nil)
    }
}
