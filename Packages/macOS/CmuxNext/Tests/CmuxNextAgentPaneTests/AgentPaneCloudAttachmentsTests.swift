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
        #expect(try await carry.uploads().isEmpty)
        let remote = try #require(carry.remapped([]))
        #expect(remote.map { $0["id"] } == chips.map { $0["id"] })
        #expect(remote[0]["data"] == .string("YWJj") && remote[0]["path"] == nil)
        #expect(remote[1]["data"] == .string("YWJj") && remote[1]["path"] == nil)
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

    @Test func theHandshakeEncodesAttachmentJSONAndDecodesItWithoutChangingTheWireShape() throws {
        var handshake = AgentPaneHandshake(transport: .acpmuxBridge)
        handshake.promptAttachments = [image, .object([
            "id": .string("paste"), "kind": .string("pasted"), "name": .string("notes.txt"),
            "text": .string("notes"), "extra": .array([.null, .bool(true), .number(1.5)]),
        ])]
        let data = try JSONEncoder().encode(handshake)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let attachments = try #require(object["promptAttachments"] as? [[String: Any]])
        #expect(attachments[0]["data"] as? String == "YWJj")
        #expect(attachments[0]["inline"] as? Bool == true)
        #expect(try JSONDecoder().decode(AgentPaneHandshake.self, from: data).promptAttachments == handshake.promptAttachments)
    }

    @MainActor @Test func theUploadFinishesBeforeTheChatOpensAndFailedOpenRollsItBack() async throws {
        let carry = try #require(AgentPaneCloudAttachments([image, image]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-attachments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [String] = []
        enum Failed: Error { case opening }
        await #expect(throws: Failed.self) {
            try await carry.withUploaded(in: root, upload: { paths in
                #expect(paths.count == 2 && paths[0] != paths[1])
                for path in paths {
                    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("abc".utf8))
                    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
                    #expect(mode?.intValue == 0o600)
                }
                events.append("uploaded")
                return .init(paths: ["/work/0/screen.png", "/work/1/screen.png"], undo: { events.append("removed") })
            }) { chips -> String in
                events.append("opened")
                #expect(chips[0]["originalPath"] == .string("/work/0/screen.png"))
                #expect(chips[1]["originalPath"] == .string("/work/1/screen.png"))
                throw Failed.opening
            }
        }
        #expect(events == ["uploaded", "opened", "removed"])
    }

    @MainActor @Test func attachmentSeedIsTakenOnlyOnce() async {
        let seed = AgentPaneSeedSource(.init(prompt: "", promptAttachments: [image], promptBy: .person))
        #expect(!seed.holdsOnlyFolder)
        #expect(await seed.take()?.promptAttachments == [image])
        #expect(await seed.take()?.promptAttachments == nil)
    }
}
