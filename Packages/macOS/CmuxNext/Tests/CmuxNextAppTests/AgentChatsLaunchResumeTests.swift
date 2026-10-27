import CmuxNextActions
@testable import CmuxNextAgentPane
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

    private static func tabs(_ listed: [(key: String, record: AgentSessionRef)], host: AgentChatsLaunchResumeRecordingHost,
                             chief: AgentChatsLaunchResumeRecordingHost? = nil) -> AgentTabStore {
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
        let host = AgentChatsLaunchResumeRecordingHost(), chief = AgentChatsLaunchResumeRecordingHost()
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
        #expect(warmed.count == 1, "one ownership census per recorded host")
        #expect(Set(warmed.flatMap { $0 }) == ["s-shown", "s-hidden", "s-hidden-2"])
        #expect(warmed.flatMap { $0 }.count == 3)
        #expect(await chief.warmed == [["s-chief"]])
    }

    @Test func aSessionThePageReportedResumesOverTheStoredOne() async {
        let host = AgentChatsLaunchResumeRecordingHost()
        let tabs = Self.tabs([(key: "tab-a", record: AgentSessionRef(host: Self.thisMac, session: "s-old"))], host: host)
        tabs.sessions["tab-a"] = "s-new"
        await tabs.resumeChatsAtLaunch()
        #expect(await host.warmed == [["s-new"]])
    }

    @Test func noChatsWarmNothing() async {
        let host = AgentChatsLaunchResumeRecordingHost()
        await Self.tabs([], host: host).resumeChatsAtLaunch()
        #expect(await host.warmed.isEmpty)
    }

    @Test func launchWaitsForTheInstallHostWithoutAnotherTreeRevision() async throws {
        let host = AgentChatsLaunchResumeRecordingHost()
        let tabs = Self.tabs([(key: "tab-a", record: AgentSessionRef(host: Self.thisMac, session: "s-late"))], host: host)
        tabs.localHost = nil
        tabs.resolveLocalHost = { Issue.record("launch must use the async install-id loader"); return nil }
        let (loads, loaded) = AsyncStream<Void>.makeStream()
        let (identities, identity) = AsyncStream<String>.makeStream()
        tabs.loadLocalHostForLaunch = {
            loaded.yield(())
            for await value in identities { return value }
            throw CancellationError()
        }
        let store = DaemonStore()
        tabs.resumeChatsWhenLoaded(store)
        defer { tabs.launchResumeTask?.cancel() }
        store.apply(.connected(DaemonIdentity(generation: DaemonGeneration(rawValue: "late-host")), generationChanged: false))
        store.apply(snapshot: DaemonTree(workspaces: []))
        _ = try await withAgentPaneDeadline(.seconds(5), label: "identity read started") {
            for await _ in loads { return true }
            return false
        }
        #expect(await host.warmed.isEmpty)
        identity.yield(Self.thisMac)
        // No store event follows the identity response.
        let session = try await withAgentPaneDeadline(.seconds(5), label: "late identity resumes chat") {
            for await value in host.resumed { return value }
            return ""
        }
        #expect(session == "s-late")
        await tabs.launchResumeTask?.value
    }

    @Test func aTransientWarmFailureRetriesWithoutAnotherTreeEvent() async {
        let host = AgentChatsLaunchResumeRecordingHost(failures: 1)
        let tabs = Self.tabs([(key: "tab", record: AgentSessionRef(host: Self.thisMac, session: "retry"))], host: host)
        #expect(await tabs.resumeChatsAtLaunch(clock: AgentLaunchTestClock()))
        #expect(await host.warmed == [["retry"], ["retry"]])
    }

    @Test func persistentWarmFailureHasABoundedNumberOfAttempts() async {
        let host = AgentChatsLaunchResumeRecordingHost(failures: 10)
        let tabs = Self.tabs([(key: "tab", record: AgentSessionRef(host: Self.thisMac, session: "retry"))], host: host)
        #expect(await tabs.resumeChatsAtLaunch(clock: AgentLaunchTestClock()) == false)
        #expect(await host.warmed.count == 3)
    }

    @Test func quitCancelsAndDrainsAnInFlightWarm() async throws {
        let host = AgentChatsLaunchResumeRecordingHost(blocked: true)
        let tabs = Self.tabs([(key: "tab", record: AgentSessionRef(host: Self.thisMac, session: "stop"))], host: host)
        let store = DaemonStore()
        tabs.resumeChatsWhenLoaded(store, clock: AgentLaunchTestClock())
        store.apply(.connected(DaemonIdentity(generation: DaemonGeneration(rawValue: "quit")), generationChanged: false))
        store.apply(snapshot: DaemonTree(workspaces: []))
        let first = try await withAgentPaneDeadline(.seconds(5), label: "warm starts") {
            for await session in host.resumed { return session }
            return ""
        }
        #expect(first == "stop")
        try await withAgentPaneDeadline(.seconds(5), label: "quit cancels launch") {
            await tabs.cancelLaunchResume()
        }
        #expect(tabs.launchResumeTask?.isCancelled == true)
        #expect(await host.warmed.count == 1)
    }

    @Test func releasingTabsBeforeConnectCancelsTheLaunchWait() async throws {
        let host = AgentChatsLaunchResumeRecordingHost(), store = DaemonStore()
        var tabs: AgentTabStore? = Self.tabs([], host: host)
        weak var released = tabs
        tabs?.resumeChatsWhenLoaded(store)
        let task = try #require(tabs?.launchResumeTask)
        tabs = nil
        #expect(released == nil)
        #expect(task.isCancelled)
        await task.value
        #expect(await host.warmed.isEmpty)
    }

    @Test func aLocalWarmFailureStillWarmsTheChiefBatch() async {
        let local = AgentChatsLaunchResumeRecordingHost(failures: 1)
        let chief = AgentChatsLaunchResumeRecordingHost()
        let router = AcpmuxChiefSessionRouter(local: local, chief: chief) { $0 == "chief" }
        await #expect(throws: AgentPaneHostError.self) {
            try await router.warm(sessionIds: ["local", "chief"])
        }
        #expect(await chief.warmed == [["chief"]])
    }

    @Test func theChiefRouterWarmsEachSessionInTheAcpmuxThatOwnsIt() async throws {
        let local = AgentChatsLaunchResumeRecordingHost(), chief = AgentChatsLaunchResumeRecordingHost()
        let router = AcpmuxChiefSessionRouter(local: local, chief: chief) { $0 == "s-subagent" }
        try await router.warm(sessionIds: ["s-chat", "s-subagent"])
        #expect(await local.warmed == [["s-chat"]])
        #expect(await chief.warmed == [["s-subagent"]])
    }
}
