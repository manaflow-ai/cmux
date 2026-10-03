import Foundation
import Testing
@testable import CmuxNextDaemon

/// Home as a workspace (plans/cmux-next/home.md 7): the wire shapes the app
/// reads (`Workspace.kind`, conversation tabs) and sends (`new-conversation-tab`).
@Suite struct HomeWorkspaceWireTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 3)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func aConversationTabDecodesItsConversationAndIsDrawnByTheApp() throws {
        let line = #"""
        {"surface":7,"kind":"conversation","browser_renderer":"frontend",
         "conversation":{"conversation":"conv_01HOME","owner":"local"}}
        """#
        let tab = try JSONDecoder().decode(TabSnapshot.self, from: Data(line.utf8))
        #expect(tab.kind == .conversation)
        #expect(tab.conversation == ConversationTabRef(conversation: "conv_01HOME", owner: "local"))
        #expect(tab.isFrontendOwned)
        // A connection without the capability reads `browser` and no record.
        let degraded = try JSONDecoder().decode(TabSnapshot.self, from: Data(
            #"{"surface":7,"kind":"browser","browser_renderer":"frontend","conversation":null}"#.utf8))
        #expect(degraded.kind == .browser && degraded.conversation == nil)
    }

    @Test func theHomeWorkspaceCarriesItsKind() throws {
        let home = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(
            #"{"id":3,"key":"k","name":"Home","active":true,"screens":[],"kind":"home"}"#.utf8))
        #expect(home.kind == "home")
        let old = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(
            #"{"id":4,"key":"j","name":"work","active":false,"screens":[]}"#.utf8))
        #expect(old.kind == nil)
    }

    @Test func newConversationTabUsesTheContractFieldNames() throws {
        let byWorkspace = try object(NewConversationTabRequest(conversation: "conv_01HOME", workspace: 3,
                                                                origin: "cmux-next-home", mutationID: "home-chief-tab"))
        #expect(byWorkspace["cmd"] == .string("new-conversation-tab"))
        #expect(byWorkspace["conversation"] == .string("conv_01HOME"))
        #expect(byWorkspace["owner"] == .string("local"))
        #expect(byWorkspace["workspace"] == .number(3))
        #expect(byWorkspace["origin"] == .string("cmux-next-home"))
        #expect(byWorkspace["mutation_id"] == .string("home-chief-tab"))
        #expect(byWorkspace["pane"] == nil || byWorkspace["pane"] == .null)
        let byPane = try object(NewConversationTabRequest(conversation: "conv_01HOME", pane: 9))
        #expect(byPane["pane"] == .number(9))
    }
}
