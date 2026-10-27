import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// cx-uw104 at the pane's page: a New Tab page is made with the chats and recently closed items
/// the app already has (`AgentPageChats.seed`), before its page has loaded. The page subscribes to
/// its host events later; the lists must reach it then, or the page says "No chats yet" until the
/// next index change.
@Suite(.serialized)
@MainActor
struct NewTabSeededListsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The newest value of each event kind the page's subscription got.
    private final class Received {
        var latest: [String: JSONValue] = [:]
    }

    @Test func listsSeededBeforeThePageLoadsReachItAtTheHandshake() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file), webUI: .agentPaneTestHost(), gestures: .testing(), deadlines: .agentPaneTesting()))
        defer { view.close() }
        // What `AgentPageChats.seed` does as the page is made: the page is still loading.
        view.deviceChats = [AgentPaneDeviceChat(key: "claude-code:s-1", harness: "claude-code", title: "Fix the flaky upload test",
                                                updatedAt: Date(timeIntervalSince1970: 1_790_000_000))]
        view.recentlyClosed = AgentPaneClosedList([AgentPaneClosedItem(id: "closed:1", kind: .terminal, title: "zsh", detail: "~/repo",
                                                   closedAt: Date(timeIntervalSince1970: 1_790_000_000), icon: nil, isAvailable: true)])

        // The page loads and subscribes to its host events.
        let received = Received()
        let subscription = try await view.pageEvents.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { event in
            if case .string(let kind)? = event["kind"], let value = event["value"] { received.latest[kind] = value }
        }
        defer { subscription.cancel() }
        for _ in 0..<400 where received.latest["deviceChats"] == nil || received.latest["recentlyClosed"] == nil { await Task.yield() }

        func ids(_ kind: String, _ field: String) -> [String?] {
            guard case .array(let items)? = received.latest[kind] else { return [] }
            return items.map { item -> String? in
                guard case .string(let id)? = item[field] else { return nil }
                return id
            }
        }
        #expect(ids("deviceChats", "key") == ["claude-code:s-1"], "the New Tab page never got the chats the app had when it was made")
        #expect(ids("recentlyClosed", "id") == ["closed:1"],
                "the New Tab page never got the recently closed items the app had when it was made")
    }
}
