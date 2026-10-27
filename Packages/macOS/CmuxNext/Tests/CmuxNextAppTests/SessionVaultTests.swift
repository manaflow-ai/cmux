import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextHistory
import Foundation
import Testing

/// The session vault (inventory row 25): past agent sessions with Open Vault as Pane and the row
/// actions Focus, Open, Resume in New Workspace, Copy Resume Command and Open Pull Request. Every
/// entrypoint (the list's context menu, `cmux action run`, MCP) runs the same registry action on
/// the invocation's `session`, else on the vault's selected row.
@MainActor @Suite(.serialized)
struct SessionVaultTests {
    static let ids: [ActionID] = ["palette.openVaultPane", "vaultFocusSession", "vaultOpenSession", "vaultResumeInNewWorkspace",
                                  "vaultCopyResumeCommand", "vaultOpenPullRequest"]

    /// Fixed sessions in place of the machines' session journals.
    @MainActor private final class FixedSource: VaultSessionSource {
        var all: [AgentSession]
        var live: Set<String> = []
        private(set) var refreshes = 0
        init(_ all: [AgentSession]) { self.all = all }
        func refresh() async { refreshes += 1 }
        func sessions() -> [AgentSession] { all }
        func isLive(_ session: AgentSession) -> Bool { live.contains(session.qualifiedID) }
    }

    @MainActor private final class Opened { var urls: [URL] = [] }

    /// What Copy Resume Command copied (tests run without a pasteboard server).
    @MainActor final class Copied { var texts: [String] = [] }

    static func session(_ id: String, provider: String = "claude", cwd: String? = "/tmp/my proj", minutesAgo: Double = 1) -> AgentSession {
        let time = Date(timeIntervalSinceNow: -minutesAgo * 60)
        return AgentSession(machine: "local", provider: provider, sessionID: id, cwd: cwd, startedAt: time, lastActivityAt: time)
    }

    static func services(_ sessions: [AgentSession], projects: URL? = nil,
                         opened: @escaping @MainActor (URL) -> Void = { _ in }) async -> (AppServices, SessionVault, Copied) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let copied = Copied()
        let vault = SessionVault(source: FixedSource(sessions), work: services.work, pullRequests: VaultPullRequests(claudeProjects: projects.map { [$0] } ?? []),
                                 copyText: { copied.texts.append($0) }, openURL: opened)
        services.vault = vault
        await vault.reload()
        return (services, vault, copied)
    }

    @Test func everyVaultActionIsAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
    }

    @Test func copyResumeCommandCopiesTheCommandInTheSessionsFolder() async {
        let (services, _, copied) = await Self.services([Self.session("abc-123")])
        let ran = services.registry.perform("vaultCopyResumeCommand", invocation: ActionInvocation(arguments: ["session": .string("abc-123")]))
        #expect(ran)
        #expect(copied.texts == ["cd -- '/tmp/my proj' && claude --resume abc-123"])
    }

    @Test func aRowActionWithoutASessionActsOnTheSelectedRowAndRefusesWithNone() async {
        let codex = Self.session("t-9", provider: "codex", cwd: nil)
        let (services, vault, copied) = await Self.services([Self.session("abc"), codex])
        #expect(vault.rows.map(\.id) == ["local/claude/abc", "local/codex/t-9"])
        let refusal = services.registry.capturingRefusal { services.registry.perform("vaultCopyResumeCommand") }
        #expect(refusal != nil, "nothing selected: the action says so")
        vault.selection = codex.qualifiedID
        services.registry.perform("vaultCopyResumeCommand")
        #expect(copied.texts == ["codex resume t-9"])
    }

    @Test func focusSessionRefusesASessionThatNoLongerRuns() async {
        let (services, _, _) = await Self.services([Self.session("gone")])
        let refusal = services.registry.capturingRefusal {
            services.registry.perform("vaultFocusSession", invocation: ActionInvocation(arguments: ["session": .string("gone")]))
        }
        #expect(refusal == VaultStrings.notRunning)
    }

    @Test func openPullRequestOpensTheNewestPullRequestTheTranscriptRecorded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-vault-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("-tmp-my-proj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","message":{"content":"open a PR"}}"#,
            #"{"type":"pr-link","prNumber":1,"prUrl":"https://github.com/o/r/pull/1","prRepository":"o/r"}"#,
            #"{"type":"assistant","message":{"content":"done"}}"#,
            #"{"type":"pr-link","prNumber":2,"prUrl":"https://github.com/o/r/pull/2","prRepository":"o/r"}"#,
            #"{"type":"assistant","message":{"content":"pr-link mention in text"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)
        let opened = Opened()
        let (services, _, _) = await Self.services([Self.session("abc"), Self.session("none")], projects: root, opened: { opened.urls.append($0) })
        let work = services.registry.capturingWork {
            services.registry.perform("vaultOpenPullRequest", invocation: ActionInvocation(arguments: ["session": .string("abc")]))
        }
        for task in work { #expect(await task.value == nil) }
        #expect(opened.urls == [try #require(URL(string: "https://github.com/o/r/pull/2"))])
        let missing = services.registry.capturingWork {
            services.registry.perform("vaultOpenPullRequest", invocation: ActionInvocation(arguments: ["session": .string("none")]))
        }
        var failures: [String] = []
        for task in missing { if let failure = await task.value { failures.append(failure.message) } }
        #expect(failures == [VaultStrings.noPullRequest])
        #expect(VaultPullRequests(claudeProjects: [root]).find(provider: "codex", sessionID: "abc") == nil, "only Claude Code records pr-link lines")
    }

    @Test func theVaultIsAnAppPageAndItsSearchFiltersRows() async {
        #expect(TabContentCache.isAppPage(URL(string: "cmux://vault")))
        #expect(!TabContentCache.isAppPage(URL(string: "cmux://vaults.example")))
        let (_, vault, _) = await Self.services([Self.session("abc", cwd: "/work/alpha"), Self.session("def", provider: "codex", cwd: "/work/beta")])
        vault.filter = "beta"
        #expect(vault.shownRows.map(\.session.sessionID) == ["def"])
        vault.filter = "claude"
        #expect(vault.shownRows.map(\.session.sessionID) == ["abc"])
    }
}
