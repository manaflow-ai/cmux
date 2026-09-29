import Foundation
import Testing
@testable import CmuxNextDaemon

@Suite struct EncodingTests {
    private func object<R: DaemonRequest>(_ request: R, id: UInt64? = 7) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: id)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func envelopeCarriesIDAndCommand() throws {
        let json = try object(SubscribeRequest())
        #expect(json["id"] == .number(7))
        #expect(json["cmd"] == .string("subscribe"))
        #expect(json["tree_events"] == .string("deltas"))
    }

    @Test func durableMutationFieldsAreSnakeCase() throws {
        let mutation = MutationIdentity(origin: "cmux-next", mutationID: "m1",
                                        expectedGeneration: "gen", expectedRevision: 4)
        let json = try object(RenameWorkspaceRequest(workspace: .key("k1"), name: "api", mutation: mutation))
        #expect(json["cmd"] == .string("rename-workspace"))
        #expect(json["key"] == .string("k1"))
        #expect(json["workspace"] == nil)
        #expect(json["name"] == .string("api"))
        #expect(json["origin"] == .string("cmux-next"))
        #expect(json["mutation_id"] == .string("m1"))
        #expect(json["expected_generation"] == .string("gen"))
        #expect(json["expected_revision"] == .number(4))
    }

    @Test func createTerminalFlattensSizeAndIdentity() throws {
        let json = try object(CreateTerminalRequest(
            workspace: .handle(3), argv: ["zsh", "-l"], cwd: "/tmp", size: CellSize(cols: 80, rows: 24),
            terminalID: "abc", mutation: MutationIdentity(origin: "o", mutationID: "m")))
        #expect(json["workspace"] == .number(3))
        #expect(json["cols"] == .number(80))
        #expect(json["rows"] == .number(24))
        #expect(json["terminal_id"] == .string("abc"))
        #expect(json["argv"] == .array([.string("zsh"), .string("-l")]))
        #expect(json["size"] == nil)
    }

    @Test func sendInputUsesBase64() throws {
        let json = try object(SendInputRequest(surface: 3, bytes: Data("echo hi\r".utf8)))
        #expect(json["bytes"] == .string(Data("echo hi\r".utf8).base64EncodedString()))
        #expect(json["surface"] == .number(3))
        #expect(json["text"] == nil)
    }

    @Test func attachByIdentityOmitsSurface() throws {
        let json = try object(AttachSurfaceRequest(surface: nil, expectedGeneration: "g", expectedTerminalID: "t",
                                                   size: CellSize(cols: 10, rows: 5)))
        #expect(json["surface"] == nil)
        #expect(json["expected_generation"] == .string("g"))
        #expect(json["expected_terminal_id"] == .string("t"))
        #expect(json["mode"] == .string("bytes"))
        #expect(json["cols"] == .number(10))
    }

    @Test func layoutAndProjectionCommands() throws {
        let split = try object(SplitRequest(pane: 4, direction: .down, tab: 9))
        #expect(split["dir"] == .string("down"))
        #expect(split["tab"] == .number(9))
        let width = try object(SetColumnWidthRequest(pane: 7, width: 0.5, transaction: 11))
        #expect(width["cmd"] == .string("set-viewport-pane-width"))
        #expect(width["transaction"] == .number(11))
        let swap = try object(SwapPaneRequest(pane: 1, target: .direction(.left)))
        #expect(swap["dir"] == .string("left"))
        let put = try object(PutFrontendProjectionRequest(
            frontend: "cmux-next", scope: .personal, subjectKey: "w1", schemaVersion: 2,
            projection: .object(["a": .bool(true)]), mutation: MutationIdentity(origin: "o", mutationID: "m")))
        #expect(put["subject_key"] == .string("w1"))
        #expect(put["schema_version"] == .number(2))
        #expect(put["projection"]?["a"] == .bool(true))
        #expect(put["mutation_id"] == .string("m"))
        let undo = try object(UndoLayoutRequest(pane: 1, revision: 3, confirmClose: true))
        #expect(undo["confirm_close"] == .bool(true))
    }

    @Test func tabDragCommandsCarryClientTransactionID() throws {
        let split = try object(TabToNewSplitRequest(surface: 3, pane: 4, edge: .left, clientTransactionID: "tx"))
        #expect(split["cmd"] == .string("tab-to-new-split"))
        #expect(split["edge"] == .string("left"))
        #expect(split["client_transaction_id"] == .string("tx"))
        let column = try object(TabToNewColumnRequest(surface: 3, screen: 5, afterColumn: 9, width: 0.5, clientTransactionID: "tx"))
        #expect(column["after_column"] == .number(9))
        #expect(column["screen"] == .number(5))
        let workspace = try object(TabToNewWorkspaceRequest(surface: 3, group: "g", index: 2))
        #expect(workspace["group"] == .string("g"))
        #expect(workspace["client_transaction_id"] == nil)
        let move = try object(MoveTabRequest(surface: 3, pane: 7, index: 0, clientTransactionID: "tx"))
        #expect(move["cmd"] == .string("move-tab"))
        #expect(move["client_transaction_id"] == .string("tx"))
        let toWorkspace = try object(MoveTabToWorkspaceRequest(surface: 3, workspace: nil))
        #expect(toWorkspace["workspace"] == nil)
    }

    @Test func windowStateDocumentRoundTripsThroughJSONValue() throws {
        var document = WindowStateDocument()
        document.upsert(WindowRecord(id: "w1", workspaceKey: "k1", frame: WindowFrame(x: 10, y: 20, width: 800, height: 600)))
        document.upsert(WindowRecord(id: "w2", workspaceKey: "gone"))
        document.upsert(WindowRecord(id: "w1", workspaceKey: "k2"))
        document.prune(liveWorkspaces: ["k2"])
        let restored = try WindowStateDocument(jsonValue: document.jsonValue())
        #expect(restored == document)
        #expect(restored.windows.map(\.id) == ["w1"])
        #expect(restored.windows[0].workspaceKey == "k2")
        #expect(try document.jsonValue()["windows"] != nil)
    }

    @Test func groupAndMetadataCommandsUseNullToClear() throws {
        let metadata = try object(SetWorkspaceMetadataRequest(workspace: .key("k1"), color: .clear, icon: .set("folder"),
                                                              mutation: MutationIdentity(origin: "o", mutationID: "m")))
        #expect(metadata["cmd"] == .string("set-workspace-metadata"))
        #expect(metadata["color"] == .null)
        #expect(metadata["icon"] == .string("folder"))
        #expect(metadata.keys.contains("title") == false)
        #expect(metadata["mutation_id"] == .string("m"))

        let ungroup = try object(MoveWorkspaceToGroupRequest(workspace: .key("k1"), group: nil, mutation: nil))
        #expect(ungroup["group"] == .null)
        #expect(ungroup["index"] == nil)
        let group = try object(MoveWorkspaceToGroupRequest(workspace: .key("k1"), group: "agents", index: 0, mutation: nil))
        #expect(group["group"] == .string("agents"))

        let update = try object(UpdateWorkspaceGroupRequest(group: "agents", color: .clear, collapsed: true))
        #expect(update["color"] == .null)
        #expect(update["collapsed"] == .bool(true))
        #expect(update["name"] == nil)
        let create = try object(CreateWorkspaceGroupRequest(name: "Agents", group: "agents"))
        #expect(create["group"] == .string("agents"))

        let browser = try object(NewFrontendBrowserTabRequest(url: "https://x", engine: .webkit, pane: 3, profileID: "p1"))
        #expect(browser["cmd"] == .string("new-frontend-browser-tab"))
        #expect(browser["engine"] == .string("webkit"))
        #expect(browser["profile_id"] == .string("p1"))
        let navigate = try object(UpdateFrontendBrowserTabRequest(surface: 5, title: "Docs", faviconURL: .clear))
        #expect(navigate["favicon_url"] == .null)
        #expect(navigate["url"] == nil)
        let pin = try object(SetTabPinnedRequest(surface: 4, pinned: true))
        #expect(pin["pinned"] == .bool(true))
    }
}
