import CmuxNextDesign
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// The in-session status cards (the live plan card and the recap card) are a Debug Settings toggle,
/// `agent.sessionStatus`, off by default. Turning it on in Debug Settings must reach an agent page
/// that is already open, without a reload, and a page made afterwards must start with it; turning
/// it off again must reach the open page too.
@Suite(.serialized)
@MainActor
struct AgentPaneSessionStatusTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The `sessionStatus` pushes the page's host event stream carried, in order.
    private final class Received {
        var values: [Bool] = []
    }

    @Test func theDebugToggleReachesAnOpenAgentPageAndANewOne() async throws {
        let store = TunableStore.shared
        let key = AgentPaneTunables.sessionStatus.key
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        store.set(key, nil)
        defer { store.set(key, nil) }
        #expect(AgentPaneTunables.sessionStatus.defaultValue == false, "in-session status is on by default")

        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file), webUI: .agentPaneTestHost(), gestures: .testing()))
        defer { view.close() }
        #expect(!view.sessionStatus)
        // The page's subscription to its host events, as the loaded page makes it.
        let received = Received()
        let subscription = try await view.pageEvents.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { event in
            if event["kind"] == .string("sessionStatus"), case .bool(let on)? = event["value"] { received.values.append(on) }
        }
        defer { subscription.cancel() }

        try #require(store.set(key, .bool(true)) == .bool(true), "the store refused the toggle")
        for _ in 0..<400 where !view.sessionStatus { await Task.yield() }
        #expect(view.sessionStatus, "Debug Settings turned in-session status on, but the open agent page kept it off")
        for _ in 0..<400 where received.values.last != true { await Task.yield() }
        #expect(received.values.last == true, "the open page never got the sessionStatus(true) event")
        #expect(AgentPanePageHost.currentEvents(view).filter { $0.kind == "sessionStatus" } == [.sessionStatus(true)],
                "a page that loads again would not get the toggle")

        let later = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file), webUI: .agentPaneTestHost(), gestures: .testing()))
        defer { later.close() }
        #expect(later.sessionStatus, "a page made with the toggle on starts with it off")

        store.set(key, nil)
        for _ in 0..<400 where view.sessionStatus { await Task.yield() }
        #expect(!view.sessionStatus, "Debug Settings turned in-session status off, but the open agent page kept it on")
        for _ in 0..<400 where received.values.last != false { await Task.yield() }
        #expect(received.values.last == false, "the open page never got the sessionStatus(false) event")
    }
}
