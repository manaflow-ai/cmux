import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Session Info drawn by the App (AgentPaneSessionInfo.swift, AgentPaneView+SessionInfo.swift): the
/// page's model makes, updates and removes the floating panel, the panel runs the pane's full height,
/// and its clicks go back to the page.
@Suite(.serialized)
@MainActor
struct AgentPaneNativeSessionInfoTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func info(open: Bool = true, width: Double = 320, top: Double = 28, side: Double = 0,
                             foot: Double? = nil) -> [String: Any] {
        var info: [String: Any] = [
            "open": open, "width": width, "top": top, "side": side, "label": "Session Info",
            "sections": [[
                "id": "subagents", "group": "running", "title": "Subagents", "meta": "1 running",
                "open": true, "foldable": true,
                "rows": [["id": "a1", "title": "rail-fix", "tone": "running", "action": "subagents.open:a1",
                          "buttons": [["label": "Stop", "action": "subagents.stop:a1"]]]],
            ]],
        ]
        if let foot { info["foot"] = foot }
        return info
    }

    private static func model(_ info: [String: Any]) throws -> AgentPaneSessionInfoModel {
        try #require(AgentPaneSessionInfoModel.decode(info))
    }

    @Test func pageModelDecodesAndBadOnesAreRefused() throws {
        let model = try Self.model(Self.info())
        #expect(model.sections.first?.rows.first?.tone == .running)
        #expect(model.sections.first?.rows.first?.buttons?.first?.action == "subagents.stop:a1")
        #expect(AgentPaneSessionInfoModel.decode(Self.info(width: .infinity)) == nil)
        #expect(AgentPaneSessionInfoModel.decode(Self.info(width: 9000)) == nil)
        #expect(AgentPaneSessionInfoModel.decode(["open": true]) == nil)
    }

    @Test func requestDecodesTheModelOrItsWithdrawal() throws {
        let request = AgentPaneRequest(body: ["id": "1", "method": "pane.sessionInfo", "params": ["info": Self.info()]])
        #expect(request == .sessionInfo(try Self.model(Self.info())))
        #expect(AgentPaneRequest(body: ["id": "2", "method": "pane.sessionInfo", "params": ["info": NSNull()]]) == .sessionInfo(nil))
        #expect(AgentPaneRequest(body: ["id": "3", "method": "pane.sessionInfo", "params": ["info": ["open": 1]]])
            == .unsupported("pane.sessionInfo"))
    }

    /// The button's on state follows the panel: open makes the panel, closed removes it.
    @Test func panelFollowsTheOpenState() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        #expect(view.model.sessionInfo.panel == nil)

        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: true))))
        let panel = try #require(view.model.sessionInfo.panel)
        #expect(panel.superview === view)
        #expect(view.model.sessionInfo.isOpen)

        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: false))))
        #expect(view.model.sessionInfo.panel == nil)
        #expect(panel.superview == nil)
        #expect(!view.model.sessionInfo.isOpen)

        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: true))))
        _ = await view.model.respond(to: .sessionInfo(nil))
        #expect(view.model.sessionInfo.panel == nil)
        view.close()
    }

    /// Debug Settings' toggle off takes the App's panel down at once (the page is told, and draws its
    /// own), and on again brings it back, with no reload.
    @Test(.timeLimit(.minutes(1))) func killSwitchTakesThePanelDownAtOnce() async throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([AgentPaneTunables.nativeSessionInfo.descriptor])
        defer { TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, nil) }
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info(open: true))))
        #expect(view.model.sessionInfo.panel != nil)

        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(false))
        while view.model.sessionInfo.panel != nil { await Task.yield() }
        #expect(!view.drawsSessionInfo)

        TunableStore.shared.set(AgentPaneTunables.nativeSessionInfo.key, .bool(true))
        while view.model.sessionInfo.panel == nil { await Task.yield() }
        view.close()
    }

    /// Full length: from under the header to the pane's foot less the float margin, at the pane's
    /// right edge; over the chat's column it stops above the composer (`foot`).
    @Test func panelRunsTheFullHeightOfThePage() throws {
        let page = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let full = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(top: 28)), width: 320, zoom: 1, flipped: true)
        #expect(full == CGRect(x: 1000 - 8 - 320, y: 28, width: 320, height: 800 - 28 - 8))
        let zoomed = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(top: 28)), width: 320, zoom: 1.25, flipped: true)
        #expect(zoomed == CGRect(x: 1000 - 10 - 400, y: 35, width: 400, height: 800 - 35 - 10))
        let beside = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(side: 300)), width: 320, zoom: 1, flipped: true)
        #expect(beside == CGRect(x: 1000 - 300 - 8 - 320, y: 28, width: 320, height: 800 - 28 - 8))
        let overChat = AgentPaneView.sessionInfoFrame(page: page, info: try Self.model(Self.info(top: 28, foot: 120)), width: 320, zoom: 1, flipped: true)
        #expect(overChat == CGRect(x: 1000 - 8 - 320, y: 28, width: 320, height: 800 - 28 - 120))
    }

    /// A click in the panel goes to the page as `sessionInfoAction`, the row's own id.
    @Test(.timeLimit(.minutes(1))) func panelClicksReachThePage() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file), pageHost: true))
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let (events, sink) = AsyncStream.makeStream(of: JSONValue.self)
        let provider = try #require(view.pageEvents)
        let subscription = try await provider.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { sink.yield($0) }
        defer { subscription.cancel() }

        _ = await view.model.respond(to: .sessionInfo(try Self.model(Self.info())))
        let panel = try #require(view.model.sessionInfo.panel)
        panel.store.act("subagents.stop:a1")
        let expected = AgentPageEvent.sessionInfoAction("subagents.stop:a1").data
        for await event in events where event["kind"] == .string("sessionInfoAction") {
            #expect(event == expected)
            break
        }
        view.close()
    }

    /// A drag of the panel's left edge widens it at once and hands the page the width when it ends.
    @Test func edgeDragWidensThePanelAndTellsThePage() throws {
        let store = AgentPaneSessionInfoStore()
        store.update(try Self.model(Self.info(width: 320)))
        var sent: [String] = []
        store.send = { sent.append($0) }
        store.drag(by: -40, ended: false)
        #expect(store.width == 360)
        #expect(sent.isEmpty)
        store.drag(by: -1000, ended: true)
        #expect(store.width == 560)
        #expect(sent == ["width:560"])
        store.update(try Self.model(Self.info(width: 560)))
        #expect(store.dragWidth == nil)
    }
}
