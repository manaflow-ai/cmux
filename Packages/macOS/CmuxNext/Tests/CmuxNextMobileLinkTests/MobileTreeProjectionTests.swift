import CmuxMobileHost
import CmuxNextDaemon
@testable import CmuxNextMobileLink
import Foundation
import Testing

@Suite("mobile tree projection")
struct MobileTreeProjectionTests {
    static func tree() throws -> DaemonTree {
        let url = try #require(Bundle.module.url(forResource: "list-workspaces-cmux-next", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let data = try JSONSerialization.data(withJSONObject: try #require(object?["data"]))
        return try JSONDecoder().decode(DaemonTree.self, from: data)
    }

    @Test func workspacesPanesAndTabsUseTheDaemonsPublicIDs() throws {
        let tree = try Self.tree()
        let projection = MobileTreeProjection(hostID: "h_mac1")
        let state = projection.state(tree)
        #expect(state.host == "h_mac1")
        let workspace = try #require(state.workspaces.first)
        #expect(workspace.id == "ws_abc80578cfad5ea82be750435458066f")
        #expect(workspace.order == 0)
        let pane = try #require(workspace.panes.first)
        #expect(pane.id == "pane_b7f856a3006ea4125256935b989f91f2")
        #expect(pane.tabs.map(\.id) == ["tab_57e65aa8804473ab94bf69f7f01a1678", "tab_ec9ce68af6c8a2c9a658e3ede0502adb",
                                        "tab_c4d56d2675fed18de155e3e204a29516"])
        #expect(pane.tabs.allSatisfy { $0.kind == .terminal && $0.terminal?.hasPrefix("term_") == true })
        // The bridge's scope check resolves a terminal through the same state.
        #expect(state.tab(showingTerminal: "term_4b79f4134c7c1bf326b4a5936dcb705f")?.id == "tab_ec9ce68af6c8a2c9a658e3ede0502adb")
    }

    @Test func opsResolvePublicIDsToDaemonHandles() throws {
        let tree = try Self.tree()
        let projection = MobileTreeProjection(hostID: "h_mac1")
        #expect(projection.workspaceKey("ws_abc80578cfad5ea82be750435458066f", in: tree)?.rawValue
            == "0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01")
        #expect(projection.surface(ofTab: "tab_ec9ce68af6c8a2c9a658e3ede0502adb", in: tree)?.rawValue == 2)
        #expect(projection.tab(showing: "term_c346421f6a0783777d843810a6ccddfa", in: tree)?.surface.rawValue == 5)
        #expect(projection.workspaceKey("ws_missing", in: tree) == nil)
        #expect(projection.tab(showing: "term_missing", in: tree) == nil)
    }
}
