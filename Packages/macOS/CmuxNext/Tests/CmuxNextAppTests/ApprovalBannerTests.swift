import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// An agent chat that asks for a tool permission gets a banner with Allow once and Deny
/// (cx-kz6m0.2, parity with classic's feed permission banners). The banner says what the agent
/// asks to do, and its buttons answer the chat's prompt through the app's acpmux answerer.
@MainActor
struct ApprovalBannerTests {
    /// Stands in for the app's acpmux: one pending prompt per session, and the answers it got.
    final class Answerer: AgentApprovalAnswering {
        var pending: [String: AgentApproval] = [:]
        var answered: [(approval: AgentApproval, allow: Bool)] = []
        var lookups: [String] = []

        func pendingApproval(session: String) async -> AgentApproval? {
            lookups.append(session)
            return pending[session]
        }

        func answer(_ approval: AgentApproval, allow: Bool) async -> Bool {
            answered.append((approval, allow))
            return true
        }
    }

    static let thisMac = "install:this-mac"
    static let bash = AgentApproval(session: "sess-1", permission: "perm-9", digest: "d1",
                                    summary: "Run tests\nswift test --filter Login")
    static let needsInput = #"{"notification":7,"title":"Fix login needs input","body":"I need to run the tests.","level":"warning","surface":1,"source":"agent"}"#

    /// Delivers daemon notification `wire` on one tab (an agent chat on `host` when `session`
    /// is set, else a terminal) and returns the service once its banner posted.
    func deliver(_ wire: String, session: String? = "sess-1", host: String = thisMac,
                 answerer: Answerer) async throws -> NotificationCenterService {
        let store = DaemonStore()
        var tab = TabSnapshot(surface: 1, kind: session == nil ? .pty : .conversation)
        if let session { tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session)) }
        let pane = PaneSnapshot(id: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "api", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let located = LocatedTab(tab: try #require(paneModel.tabs.first), pane: paneModel, workspace: workspace)
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        let service = NotificationCenterService()
        service.approvals.answerer = answerer
        service.localAgentHost = { Self.thisMac }
        var decision = NotificationPolicy.Decision()
        decision.desktop = true
        let source = NotificationSource(rawValue: notification.source ?? "") ?? .agent
        service.deliver(notification, source: source, located: located, decision: decision, program: nil)
        // The banner may wait for the chat's prompt to be read.
        for _ in 0..<200 where service.desktop.posted.isEmpty { await Task.yield() }
        return service
    }

    @Test func aChatPermissionBannerOffersAllowOnceAndDenyAndSaysWhatItAllows() async throws {
        let answerer = Answerer()
        answerer.pending["sess-1"] = Self.bash
        let service = try await deliver(Self.needsInput, answerer: answerer)
        let posted = try #require(service.desktop.posted.last)
        #expect(posted.approval, "the banner carries the Allow once / Deny category")
        #expect(posted.title == "api")
        #expect(posted.subtitle == "Fix login needs input")
        #expect(posted.body == "Run tests\nswift test --filter Login")
    }

    @Test func allowOnceAndDenyAnswerTheChatsPrompt() async throws {
        let answerer = Answerer()
        answerer.pending["sess-1"] = Self.bash
        let service = try await deliver(Self.needsInput, answerer: answerer)
        let posted = try #require(service.desktop.posted.last)
        // The answer runs off main (a background task); the test waits for it.
        _ = try await #require(service.answerApproval(banner: posted.id, surface: SurfaceID(rawValue: 1), allow: true)).value
        #expect(answerer.answered.map(\.approval) == [Self.bash])
        #expect(answerer.answered.map(\.allow) == [true])

        let denied = Answerer()
        denied.pending["sess-1"] = Self.bash
        let other = try await deliver(Self.needsInput, answerer: denied)
        let deny = other.answerApproval(banner: try #require(other.desktop.posted.last).id, surface: SurfaceID(rawValue: 1), allow: false)
        _ = try await #require(deny).value
        #expect(denied.answered.map(\.allow) == [false])
    }

    @Test func noPromptAnotherMacOrATerminalKeepsAPlainBanner() async throws {
        // A question (or nothing pending): the answerer finds no permission.
        let none = Answerer()
        let plain = try #require(try await deliver(Self.needsInput, answerer: none).desktop.posted.last)
        #expect(!plain.approval)
        #expect(plain.body == "I need to run the tests.")

        // A chat on another Mac's acpmux: this Mac never asks or answers for it.
        let elsewhere = Answerer()
        elsewhere.pending["sess-1"] = Self.bash
        let remote = try #require(try await deliver(Self.needsInput, host: "install:other", answerer: elsewhere).desktop.posted.last)
        #expect(!remote.approval)
        #expect(elsewhere.lookups.isEmpty)

        // A terminal agent's hook approval has no prompt this app can answer.
        let terminal = Answerer()
        let hook = #"{"notification":8,"title":"Claude needs approval","body":"Bash","level":"warning","surface":1,"source":"agent"}"#
        let posted = try #require(try await deliver(hook, session: nil, answerer: terminal).desktop.posted.last)
        #expect(!posted.approval)
        #expect(terminal.lookups.isEmpty)
    }

    @Test func aBannerThisLaunchDidNotPostAnswersNothing() async throws {
        let answerer = Answerer()
        answerer.pending["sess-1"] = Self.bash
        let service = try await deliver(Self.needsInput, answerer: answerer)
        #expect(service.answerApproval(banner: "cmux-notification-1", surface: SurfaceID(rawValue: 1), allow: true) == nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(answerer.answered.isEmpty)
    }

    /// Holds each prompt read until the test releases it, as a slow acpmux would.
    final class SlowAnswerer: AgentApprovalAnswering {
        var approval: AgentApproval?
        var waiting: [CheckedContinuation<Void, Never>] = []

        func pendingApproval(session: String) async -> AgentApproval? {
            await withCheckedContinuation { waiting.append($0) }
            return approval
        }

        func answer(_ approval: AgentApproval, allow: Bool) async -> Bool { true }

        func release() {
            let held = waiting
            waiting = []
            held.forEach { $0.resume() }
        }
    }

    /// One agent chat tab on this Mac, and a service that answers through `answerer`.
    func chat(answerer: any AgentApprovalAnswering) throws -> (NotificationCenterService, LocatedTab) {
        let store = DaemonStore()
        var tab = TabSnapshot(surface: 1, kind: .conversation)
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.thisMac, session: "sess-1"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "api", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let pane = try #require(workspace.screens.first?.panes.first)
        let service = NotificationCenterService()
        service.approvals.answerer = answerer
        service.localAgentHost = { Self.thisMac }
        return (service, LocatedTab(tab: try #require(pane.tabs.first), pane: pane, workspace: workspace))
    }

    /// "Fix login needs input" as daemon notification `id`, delivered on `located`.
    func ask(_ id: Int, _ service: NotificationCenterService, _ located: LocatedTab) throws {
        let wire = #"{"notification":\#(id),"title":"Fix login needs input","body":"","level":"warning","surface":1,"source":"agent"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        var decision = NotificationPolicy.Decision()
        decision.desktop = true
        service.deliver(notification, source: .agent, located: located, decision: decision, program: nil)
    }

    @Test func aChatReadWhileItsPromptIsReadPostsNoBanner() async throws {
        let slow = SlowAnswerer()
        slow.approval = Self.bash
        let (service, located) = try chat(answerer: slow)
        try ask(7, service, located)
        for _ in 0..<200 where slow.waiting.isEmpty { await Task.yield() }
        // The user looked at the chat (or answered it there) before acpmux replied.
        service.acknowledge(located.tab)
        slow.release()
        for _ in 0..<200 { await Task.yield() }
        #expect(service.desktop.posted.isEmpty, "no banner for a notification already read")
    }

    @Test func aNewerAskWhileTheFirstIsReadPostsOnlyTheNewerBanner() async throws {
        let slow = SlowAnswerer()
        slow.approval = Self.bash
        let (service, located) = try chat(answerer: slow)
        try ask(7, service, located)
        for _ in 0..<200 where slow.waiting.isEmpty { await Task.yield() }
        try ask(8, service, located)
        for _ in 0..<200 where slow.waiting.count < 2 { await Task.yield() }
        slow.release()
        for _ in 0..<200 { await Task.yield() }
        #expect(service.desktop.posted.map(\.id) == ["cmux-notification-8"])
    }

    @Test func aNewerApprovalBannerRetiresTheOlderOnesButtons() async throws {
        let answerer = Answerer()
        answerer.pending["sess-1"] = Self.bash
        let (service, located) = try chat(answerer: answerer)
        try ask(7, service, located)
        for _ in 0..<200 where service.desktop.posted.isEmpty { await Task.yield() }
        try ask(8, service, located)
        for _ in 0..<200 where service.desktop.posted.count < 2 { await Task.yield() }
        #expect(service.answerApproval(banner: "cmux-notification-7", surface: SurfaceID(rawValue: 1), allow: true) == nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(answerer.answered.isEmpty, "the older banner's prompt is the newer one's now")
        _ = try await #require(service.answerApproval(banner: "cmux-notification-8", surface: SurfaceID(rawValue: 1), allow: true)).value
        #expect(answerer.answered.map(\.allow) == [true])
    }
}
