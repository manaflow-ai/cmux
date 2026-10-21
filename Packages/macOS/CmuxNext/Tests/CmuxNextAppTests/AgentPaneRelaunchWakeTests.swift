import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-20: "After nightlies, have the things running, but have the views go back to where
/// they were." A chat's composer held more than acpmux's draft text: its attachment chips and shell
/// mode with its unrun command. Hibernation kept them in memory only, so a relaunch (Restart to
/// Update, SIGTERM's Quit and keep sessions, Cmd-Q) dropped them. The quit's window step now saves
/// what every chat page holds, live or released, and the next launch hands it to each tab's first
/// page with its handshake, once.
@MainActor @Suite(.serialized)
struct AgentPaneRelaunchWakeTests {
    static let thisMac = "install:agent-pane-relaunch-wake-test"

    /// A tab store of one run, as the App wires it: tab records in a tree, pages on a page that
    /// never loads (a loopback port nobody serves), the wake file of the tag's state directory.
    static func run(file: URL, records: [String: AgentSessionRef]) -> AgentTabStore {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = thisMac
        tabs.relaunchWake = AgentPaneRelaunchWake(file: file)
        let tree = DaemonStore()
        tabs.lookup = { key in records[key].map { ($0, tree) } }
        return tabs
    }

    final class Asked { var count = 0 }

    static func ready(_ page: AgentPaneView) async throws -> [String: Any] {
        let reply = await page.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        return try #require(reply["value"] as? [String: Any], "\(reply)")
    }

    @Test func aChatsComposerComesBackAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentPaneRelaunchWake.fileName)
        let records = [
            "tab_shown": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-shown", harness: "claude"),
            "tab_released": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-released", harness: "claude"),
        ]
        let shownHeld = AgentPaneWakeState(
            attachments: [AgentPaneWakeState.Attachment(id: "a1", kind: "image", name: "shot.png", mimeType: "image/png", size: 4, data: "iVBO")],
            shell: true, shellText: "git status", scrollAnchor: AgentPaneScrollAnchor(rowId: "row-12", offset: 40))
        let releasedHeld = AgentPaneWakeState(shell: true, shellText: "make test")

        // This run: one chat's page is live, the other's let go (hibernation) and its tab kept what it held.
        let before = Self.run(file: file, records: records)
        let shown = try #require(before.view(for: "tab_shown"))
        _ = try await Self.ready(shown)
        before.wakeStates["tab_released"] = releasedHeld
        // A tab that left every tree (closed elsewhere) keeps nothing.
        before.wakeStates["tab_gone"] = AgentPaneWakeState(shell: true, shellText: "rm -rf build")
        before.relaunchWake.read = { page, _ in page === shown ? shownHeld : nil }
        // The quit's window step (every relaunch's quit goes through it).
        await before.relaunchWake.save(before.relaunchWakeStates())

        // The next run: each tab's first page gets its chat's composer back with its handshake.
        let after = Self.run(file: file, records: records)
        after.wakeStates = after.relaunchWake.take()
        #expect(after.wakeStates["tab_gone"] == nil, "a closed tab's composer was kept")
        let shownPage = try #require(after.view(for: "tab_shown"))
        let shownHandshake = try await Self.ready(shownPage)
        let shownWake = try #require(shownHandshake["wake"] as? [String: Any], "the live chat came back without its composer")
        let attachments = try #require(shownWake["attachments"] as? [[String: Any]])
        #expect(attachments.map { $0["name"] as? String } == ["shot.png"])
        #expect(attachments.first?["data"] as? String == "iVBO")
        #expect(shownWake["shell"] as? Bool == true)
        #expect(shownWake["shellText"] as? String == "git status")
        #expect((shownWake["scrollAnchor"] as? [String: Any])?["rowId"] as? String == "row-12")
        let releasedPage = try #require(after.view(for: "tab_released"))
        let releasedHandshake = try await Self.ready(releasedPage)
        let releasedWake = try #require(releasedHandshake["wake"] as? [String: Any], "the released chat came back without its composer")
        #expect(releasedWake["shellText"] as? String == "make test")

        // Handed back once: a crash after this launch never brings back chips already sent.
        let third = Self.run(file: file, records: records)
        third.wakeStates = third.relaunchWake.take()
        #expect(third.wakeStates.isEmpty)
    }

    /// A restored New Tab page with chips from the last quit never adopts the prewarmed spare (its
    /// handshake is long past): it gets a page of its own whose handshake carries them, and the
    /// state is gone from the store, so no later page brings it back.
    @Test func aRestoredNewTabPageGetsItsComposerInsteadOfTheSpare() async throws {
        let store = DaemonStore()
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.thisMac))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [page])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"], showcase: true)
        tabs.localHost = Self.thisMac
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        let handler = NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in })
        tabs.firstPageNewTab = { _, _ in (AgentPaneNewTab(kind: .agent), handler) }
        tabs.blankChatHandler = { _ in handler }
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        tabs.takeSpare = { spare }
        let key = try #require(store.tab(surface: 1)?.id)
        tabs.wakeStates[key] = AgentPaneWakeState(shell: true, shellText: "npm run dev")

        let view = try #require(tabs.view(for: key))
        #expect(view !== spare, "the restored page adopted the spare and dropped its composer")
        #expect(tabs.wakeStates[key] == nil, "the restored state stayed in the store")
        let wake = try #require(try await Self.ready(view)["wake"] as? [String: Any], "the restored New Tab page lost its composer")
        #expect(wake["shellText"] as? String == "npm run dev")
    }

    /// A live page that does not answer in time, or whose own ready has not come yet (only a
    /// reconnect handshake), keeps the state it was built with instead of saving nothing.
    @Test func aPageThatDoesNotAnswerKeepsItsState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        let records = ["tab_slow": AgentSessionRef(host: Self.thisMac, hostName: "This Mac", session: "s-slow", harness: "claude")]
        let tabs = Self.run(file: directory.appending(path: AgentPaneRelaunchWake.fileName), records: records)
        let held = AgentPaneWakeState(shell: true, shellText: "cargo test")
        tabs.wakeStates["tab_slow"] = held
        let page = try #require(tabs.view(for: "tab_slow"))
        _ = await page.model.respond(to: AgentPaneRequest(body: ["method": "reconnect"]))
        let asked = Asked()
        tabs.relaunchWake.read = { _, _ in
            asked.count += 1
            return nil
        }
        #expect(await tabs.relaunchWakeStates()["tab_slow"] == held, "a page that had not taken its state dropped it")
        #expect(asked.count == 0, "a page that had not taken its state was asked for one")

        // After its ready, a page that does not answer in time keeps the tab's kept state.
        _ = try await Self.ready(page)
        tabs.wakeStates["tab_slow"] = held
        #expect(await tabs.relaunchWakeStates()["tab_slow"] == held, "a page that did not answer in time saved nothing over it")
        #expect(asked.count == 1)
    }

    /// A chat whose page holds nothing saves nothing, and with nothing held the file goes.
    @Test func anEmptyComposerLeavesNoFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "relaunch-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentPaneRelaunchWake.fileName)
        let store = AgentPaneRelaunchWake(file: file)
        await store.save(["tab_a": AgentPaneWakeState(shell: true, shellText: "ls")])
        #expect(FileManager.default.fileExists(atPath: file.path), "a held shell command was not saved")
        await store.save(["tab_a": AgentPaneWakeState()])
        #expect(!FileManager.default.fileExists(atPath: file.path), "an empty composer left a file")
    }
}
