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

    /// Leo, 2026-11-08: "Can I upload files in there?" A PDF dropped from Finder on a new Cloud chat's
    /// first send goes to the machine by its own path (no copy read into memory, so any size goes),
    /// and its chip names only the machine's copy.
    @MainActor @Test func aDroppedPdfOnTheFirstSendUploadsByPathAndRemapsToTheMachine() async throws {
        let mac = "/Users/me/Downloads/report.pdf"
        let pdf: JSONValue = .object(["id": .string("link:" + mac), "kind": .string("link"), "name": .string("report.pdf"),
                                      "mimeType": .string(""), "size": .number(0), "path": .string(mac)])
        let carry = try #require(AgentPaneCloudAttachments([pdf, image], files: [mac]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-attachments-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var undone = false
        let chips = try await carry.withUploaded(in: root, upload: { paths in
            #expect(paths.count == 2)
            #expect(paths.first == mac, "the dropped file goes by its own path")
            #expect(paths.last?.hasPrefix(root.path) == true, "the image goes as its private copy")
            return .init(paths: ["/work/0/report.pdf", "/work/1/screen.png"], undo: { undone = true })
        }) { $0 }
        #expect(!undone)
        #expect(chips[0]["path"] == .string("/work/0/report.pdf"))
        #expect(chips[0]["saved"] == .bool(true))
        #expect(chips[0]["originalPath"] == nil)
        #expect(chips[1]["originalPath"] == .string("/work/1/screen.png"))
        #expect(!chips.contains { $0["path"] == .string(mac) || $0["originalPath"] == .string("/Users/me/Desktop/screen.png") })
        #expect(carry.remapped(["/work/0/report.pdf"]) == nil, "every carried file needs its machine path")
    }

    /// A file this app saved under Chat Uploads (in ~/Library, which the upload CLI refuses to read)
    /// goes as a private clone in the paste folder, never as its own path.
    @MainActor @Test func aSavedChatUploadIsClonedIntoThePasteFolderFirst() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-staged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let saved = base.appendingPathComponent("Chat Uploads/notes.txt")
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: saved)
        let chip: JSONValue = .object(["id": .string("link:" + saved.path), "kind": .string("link"), "name": .string("notes.txt"),
                                       "path": .string(saved.path), "saved": .bool(true)])
        let carry = try #require(AgentPaneCloudAttachments([chip], files: [saved.path], staged: [saved.path]))
        let pastes = base.appendingPathComponent("cmux-pastes")
        let chips = try await carry.withUploaded(in: pastes, upload: { paths in
            #expect(paths.count == 1)
            #expect(paths[0] != saved.path && paths[0].hasPrefix(pastes.path))
            #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == Data("notes".utf8))
            let mode = try FileManager.default.attributesOfItem(atPath: paths[0])[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
            return .init(paths: ["/work/0/notes.txt"], undo: {})
        }) { $0 }
        #expect(chips[0]["path"] == .string("/work/0/notes.txt") && chips[0]["saved"] == .bool(true))
        // A relative link to it stages the file it names, not a link that would dangle in the copy.
        let link = saved.deletingLastPathComponent().appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "notes.txt")
        let linked: JSONValue = .object(["id": .string("link:" + link.path), "kind": .string("link"), "name": .string("link.txt"), "path": .string(link.path)])
        let viaLink = try #require(AgentPaneCloudAttachments([linked], files: [link.path], staged: [link.path]))
        _ = try await viaLink.withUploaded(in: pastes, upload: { paths in
            let kind = try FileManager.default.attributesOfItem(atPath: paths[0])[.type] as? FileAttributeType
            #expect(kind == .typeRegular, "a link was copied")
            #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == Data("notes".utf8))
            return .init(paths: ["/work/1/notes.txt"], undo: {})
        }) { $0 }
    }

    /// A link chip whose path the pane never authorized (page script made it up) is still refused,
    /// a folder's too. A folder the pane authorized goes by its path, and its chip becomes a saved
    /// link to the machine's copy with its name kept.
    @MainActor @Test func aPageInventedPathIsRefusedAndAnAuthorizedFolderGoes() async throws {
        let invented: JSONValue = .object(["id": .string("x"), "kind": .string("link"), "name": .string("id_ed25519"),
                                           "path": .string("/Users/me/.ssh/id_ed25519")])
        #expect(AgentPaneCloudAttachments([invented], files: ["/Users/me/Downloads/report.pdf"]) == nil)
        #expect(AgentPaneCloudAttachments.refusal([invented]).contains("needs a local file"))
        let folder: JSONValue = .object(["id": .string("link:/Users/me/docs"), "kind": .string("link"), "name": .string("docs/"),
                                         "path": .string("/Users/me/docs")])
        #expect(AgentPaneCloudAttachments([folder], files: ["/Users/me/other"]) == nil)
        #expect(AgentPaneCloudAttachments.refusal([image, folder]).contains("needs a local file"))
        let carry = try #require(AgentPaneCloudAttachments([folder], files: ["/Users/me/docs"]))
        let pastes = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-pastes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pastes) }
        let chips = try await carry.withUploaded(in: pastes, upload: { paths in
            #expect(paths == ["/Users/me/docs"], "the folder goes by its own path")
            return .init(paths: ["/work/local/uploads/0/docs"], undo: {})
        }) { $0 }
        #expect(chips[0]["path"] == .string("/work/local/uploads/0/docs") && chips[0]["saved"] == .bool(true))
        #expect(chips[0]["name"] == .string("docs/"))
        let nameless: JSONValue = .object(["id": .string("link:/"), "kind": .string("link"), "name": .string("/"), "path": .string("/")])
        #expect(AgentPaneCloudAttachments([nameless], files: ["/"]) == nil)
        let slashedText: JSONValue = .object(["id": .string("t"), "kind": .string("text"), "name": .string("notes/"), "text": .string("x")])
        #expect(AgentPaneCloudAttachments([slashedText]) == nil, "only a link names a folder")
    }

    @MainActor @Test func attachmentSeedIsTakenOnlyOnce() async {
        let seed = AgentPaneSeedSource(.init(prompt: "", promptAttachments: [image], promptBy: .person))
        #expect(!seed.holdsOnlyFolder)
        #expect(await seed.take()?.promptAttachments == [image])
        #expect(await seed.take()?.promptAttachments == nil)
    }
}
