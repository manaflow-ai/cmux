import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite(.serialized)
@MainActor
struct AgentPaneNativeToolsHostTests {
    actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    func enableTools() -> () -> Void {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(DesignTunables.all)
        let key = ChromeTunables.nativeRowTools.key
        let previous = store.override(key)
        store.set(key, .bool(true))
        return { store.set(key, previous) }
    }

    private var tool: PaneTabRowTool {
        PaneTabRowTool(id: "project", symbol: "folder", label: "Project", enabled: true, toggled: false)
    }

    @Test func unsupportedHostsKeepWebControlsAndRejectNativePublication() async throws {
        let restore = enableTools()
        defer { restore() }
        let file = try #require(AgentPageTestRoot.page)
        let url = try #require(URL(string: "http://127.0.0.1:4173"))
        for source in [AgentPaneSource.bundled(file), .devServer(url)] {
            let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: source,
                                                  pageHost: source != .bundled(file), chromium: nil))
            defer { view.close() }
            #expect(view.pageEvents == nil)
            #expect(!view.model.tabRow.nativeToolsEnabled)
            AgentPaneTabRow.offer(points: 36, trailingInset: 40, to: view)
            #expect(view.model.tabRow.event.value["nativeRowTools"]?.boolValue == false)
            _ = await view.model.respond(to: .tabRowToolsSet([tool]))
            #expect(view.model.tabRowTools.isEmpty)
        }
    }

    @Test func sharedHostPublishesCapabilityAndAcceptsToolsOnlyWhileEnabled() async throws {
        let restore = enableTools()
        defer { restore() }
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: nil))
        defer { view.close() }
        #expect(view.pageEvents != nil)
        #expect(view.model.tabRow.nativeToolsEnabled)
        AgentPaneTabRow.offer(points: 36, trailingInset: 40, to: view)
        _ = await view.model.respond(to: .tabRowToolsSet([tool]))
        #expect(view.model.tabRowTools == [tool])
        let replay = try #require(AgentPanePageHost.currentEvents(view).first { $0.kind == "tabRow" })
        #expect(replay.value["nativeRowTools"]?.boolValue == true)
        TunableStore.shared.set(ChromeTunables.nativeRowTools.key, .bool(false))
        AgentPaneTabRow.offer(points: 36, trailingInset: 40, to: view)
        #expect(view.model.tabRow.event.value["nativeRowTools"]?.boolValue == false)
        _ = await view.model.respond(to: .tabRowToolsSet([]))
        #expect(view.model.tabRowTools == [tool], "a disabled capability must ignore page publications")
    }

}
