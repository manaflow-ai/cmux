import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-z5vd: a new chat's typed text, from before it has an acpmux session, comes back after a
/// relaunch. The page's `chat.unsentDraft` reaches the tab's kept drafts on disk, and the next run
/// opens that tab as the chat with the text as its draft (not as the New Tab page). Once the chat
/// has a session, acpmux keeps its draft and the tab's copy is gone.
@MainActor
struct UnsentDraftTests {
    static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func aNewChatsTypedTextComesBackAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)

        // This run's drafts, held as the tab store holds them.
        let drafts = AgentUnsentDrafts(file: file)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "compare the two retry policies"]))

        // The next run's tab, still without a session, opens as the chat with its draft.
        let relaunched = AgentUnsentDrafts(file: file)
        let seed = try #require(relaunched.seed(for: "tab-1", session: nil))
        #expect(await seed.take()?.draft == "compare the two retry policies")
        #expect(relaunched.seed(for: "tab-1", session: "s-1") == nil, "a chat with a session keeps its draft in acpmux")
        #expect(relaunched.seed(for: "tab-2", session: nil) == nil)

        // The first prompt starts the chat's session: the tab's copy goes, and later text is acpmux's.
        _ = await model.respond(to: Self.request("chat.persistSession", ["sessionId": "s-1"]))
        #expect(AgentUnsentDrafts(file: file).seed(for: "tab-1", session: nil) == nil)
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "later"]))
        #expect(AgentUnsentDrafts(file: file).seed(for: "tab-1", session: nil) == nil)
        withExtendedLifetime(drafts) {}
    }

    /// #17587: the launch reads the drafts off the main thread from the top of `main`
    /// (`LaunchFiles`, a `LaunchRead`); the tab store, made on the main thread in
    /// `applicationDidFinishLaunching`, only takes them and reads no file. Through the services' own
    /// wiring (`AgentTabStore.wired`), the one path every launch takes.
    @Test func theTabStoreTakesTheDraftsTheLaunchReadOffTheMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try #require(AgentUnsentDrafts.file(in: directory))
        try JSONEncoder().encode(["tab-1": "kept text"]).write(to: file)

        var environment = AppEnvironment.current([:])
        environment.sidebarSnapshotFile = SidebarSnapshotFile(url: directory.appending(path: SidebarSnapshotFile.fileName))
        let services = AppServices(environment: environment)
        await services.launchFiles.agent.unsentDrafts.backgroundReadFinished()
        // The file is gone before the store is made: the store holds what the launch read.
        try FileManager.default.removeItem(at: file)
        let seed = try #require(services.agentTabs.unsentDrafts.seed(for: "tab-1", session: nil))
        #expect(await seed.take()?.draft == "kept text")
    }
}
