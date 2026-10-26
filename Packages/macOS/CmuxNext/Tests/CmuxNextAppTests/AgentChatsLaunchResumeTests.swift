import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// cmux#22292: after a relaunch every chat tab of this Mac resumes its agent at launch, in every
/// workspace, not only the chats of the workspace shown (a chat's page, and with it its session,
/// is made only when its tab first shows). Each session warms once, through this Mac's acpmux.
@MainActor
struct AgentChatsLaunchResumeTests {
    private static let thisMac = "install:launch-resume-test"

    /// The sessions the store asked acpmux to warm, one call each.
    private actor RecordingHost: AgentPaneHostProviding {
        var warmed: [[String]] = []
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
        func warm(sessionIds: [String]) async throws { warmed.append(sessionIds) }
    }

    private static func tabs(_ listed: [(key: String, record: AgentSessionRef)], host: RecordingHost,
                             chief: RecordingHost? = nil) -> AgentTabStore {
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: environment, showcase: true)
        tabs.localHost = thisMac
        tabs.localSessionHost = host
        if let chief {
            tabs.chiefHost = "chief:launch-resume-test"
            tabs.chiefPaneHost = chief
        }
        tabs.listTabs = { listed }
        return tabs
    }

    @Test func everyWorkspacesChatsOfThisMacResumeAtLaunchOnceEach() async {
        let host = RecordingHost(), chief = RecordingHost()
        let tabs = Self.tabs([
            // The workspace shown at launch.
            (key: "tab-a", record: AgentSessionRef(host: Self.thisMac, session: "s-shown", harness: "codex")),
            // Workspaces never selected since the relaunch.
            (key: "tab-b", record: AgentSessionRef(host: Self.thisMac, session: "s-hidden", harness: "claude")),
            (key: "tab-c", record: AgentSessionRef(host: Self.thisMac, session: "s-hidden-2", harness: "codex")),
            // A second tab on the same chat warms it once.
            (key: "tab-d", record: AgentSessionRef(host: Self.thisMac, session: "s-hidden", harness: "claude")),
            // A Chief subagent listed in this Mac's tree warms through the Chief acpmux.
            (key: "tab-chief", record: AgentSessionRef(host: "chief:launch-resume-test", session: "s-chief", harness: "claude")),
            // A New Tab page or new chat has no session to resume.
            (key: "tab-e", record: AgentSessionRef(host: Self.thisMac)),
            // Another machine's chat runs there, never in this Mac's acpmux.
            (key: "tab-f", record: AgentSessionRef(host: "install:another-mac", session: "s-elsewhere")),
        ], host: host, chief: chief)

        await tabs.resumeChatsAtLaunch()
        let warmed = await host.warmed
        #expect(warmed.allSatisfy { $0.count == 1 })
        #expect(Set(warmed.flatMap { $0 }) == ["s-shown", "s-hidden", "s-hidden-2"])
        #expect(warmed.count == 3)
        #expect(await chief.warmed == [["s-chief"]])
    }

    @Test func aSessionThePageReportedResumesOverTheStoredOne() async {
        let host = RecordingHost()
        let tabs = Self.tabs([(key: "tab-a", record: AgentSessionRef(host: Self.thisMac, session: "s-old"))], host: host)
        tabs.sessions["tab-a"] = "s-new"
        await tabs.resumeChatsAtLaunch()
        #expect(await host.warmed == [["s-new"]])
    }

    @Test func noChatsWarmNothing() async {
        let host = RecordingHost()
        await Self.tabs([], host: host).resumeChatsAtLaunch()
        #expect(await host.warmed.isEmpty)
    }

    @Test func theChiefRouterWarmsEachSessionInTheAcpmuxThatOwnsIt() async throws {
        let local = RecordingHost(), chief = RecordingHost()
        let router = AcpmuxChiefSessionRouter(local: local, chief: chief) { $0 == "s-subagent" }
        try await router.warm(sessionIds: ["s-chat", "s-subagent"])
        #expect(await local.warmed == [["s-chat"]])
        #expect(await chief.warmed == [["s-subagent"]])
    }
}
