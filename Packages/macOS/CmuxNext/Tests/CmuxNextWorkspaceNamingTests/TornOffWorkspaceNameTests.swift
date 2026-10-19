import CmuxNextBridge
@testable import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextWorkspaceNaming

/// A window torn off from an agent chat read "workspace-40", "workspace-41" (Leo 2026-10-19): the
/// tear-off named its workspace from the chat tab's record, which carries no title or folder, so
/// the daemon's default stayed, and the window's titlebar showed that name where its sidebar row
/// showed the chat's title. A workspace made from a chat takes the chat's name, and a titlebar
/// names a workspace as its sidebar row does.
@MainActor
struct TornOffWorkspaceNameTests {
    static let host = "install:tear-off"

    static func chatTab(_ session: String, surface: UInt64 = 1, name: String? = nil) -> TabModel {
        var snapshot = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, name: name, cwd: nil)
        snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
        return TabModel(snapshot)
    }

    /// Chats titled by their agent (`generated`), or only by their first prompt.
    static func turns(_ titles: [String: String], generated: Bool = true) -> AgentTurnStateStore {
        let turns = AgentTurnStateStore()
        turns.localHost = host
        for (session, title) in titles {
            turns.apply(session: session, state: nil, lastMessage: nil, muted: false, title: title,
                        generatedTitle: generated ? title : nil, detail: nil)
        }
        return turns
    }

    static func reader(_ turns: AgentTurnStateStore, newTabPages: Set<String> = []) -> WorkspaceAutoNameReader {
        WorkspaceAutoNameReader(
            enabled: { true }, isNewTabPage: { newTabPages.contains($0.id) }, livePage: { _ in nil },
            incognitoTitle: { _ in nil },
            terminal: { NewWorkspaceName.Tab(kind: .terminal, userName: $0.name, title: $0.title, pageTitle: nil, url: $0.url, cwd: $0.cwd) },
            turns: turns)
    }

    static func workspace(_ name: String, title: String? = nil) throws -> WorkspaceModel {
        let titled = title.map { #","title":"\#($0)""# } ?? ""
        let json = #"{"id":1,"key":"w","name":"\#(name)"\#(titled),"screens":[]}"#
        return WorkspaceModel(try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8)))
    }

    @Test func aChatTornOffNamesItsWorkspaceForTheChat() {
        let reader = Self.reader(Self.turns(["s1": "Fix the sidebar drag"]))
        #expect(reader.newWorkspaceName(Self.chatTab("s1")) == "Fix the sidebar drag")
    }

    @Test func aChatTheUserNamedNamesItsWorkspaceSo() {
        let reader = Self.reader(Self.turns(["s1": "Fix the sidebar drag"]))
        #expect(reader.newWorkspaceName(Self.chatTab("s1", name: "Release notes")) == "Release notes")
    }

    @Test func aChatTitledOnlyByItsFirstPromptKeepsTheDaemonsNameButReadsAsTheChat() throws {
        // A name written now lasts: the prompt would stand in for the agent's title for good.
        let reader = Self.reader(Self.turns(["s1": "fix the flaky test in Foo"], generated: false))
        #expect(reader.newWorkspaceName(Self.chatTab("s1")) == nil)
        #expect(reader.displayName(try Self.workspace("workspace-41"), front: Self.chatTab("s1")) == "fix the flaky test in Foo")
    }

    @Test func aNewTabPageKeepsTheDaemonsName() {
        let tab = Self.chatTab("s2")
        let reader = Self.reader(Self.turns(["s2": "An older chat"]), newTabPages: [tab.id])
        #expect(reader.newWorkspaceName(tab) == nil)
    }

    @Test func theLastTabOfAWorkspaceTheUserNamedKeepsThatName() {
        let tabName = Self.reader(Self.turns(["s1": "Fix the sidebar drag"])).newWorkspaceName(Self.chatTab("s1"))
        #expect(NewWorkspaceName.forLastTab(workspaceName: "Sidebar", workspaceTitle: nil, tabName: tabName) == "Sidebar")
        #expect(NewWorkspaceName.forLastTab(workspaceName: "workspace-40", workspaceTitle: nil, tabName: tabName)
            == "Fix the sidebar drag")
    }

    @Test func aTitlebarNamesADefaultNamedWorkspaceForItsFrontChat() throws {
        let reader = Self.reader(Self.turns(["s1": "Fix the sidebar drag"]))
        #expect(reader.displayName(try Self.workspace("workspace-41"), front: Self.chatTab("s1")) == "Fix the sidebar drag")
    }

    @Test func aTitlebarKeepsAWorkspacesOwnName() throws {
        let reader = Self.reader(Self.turns(["s1": "Fix the sidebar drag"]))
        #expect(reader.displayName(try Self.workspace("Sidebar"), front: Self.chatTab("s1")) == "Sidebar")
        #expect(reader.displayName(try Self.workspace("workspace-41", title: "Launch"), front: Self.chatTab("s1")) == "Launch")
        #expect(reader.displayName(try Self.workspace("workspace-41"), front: nil) == "workspace-41")
    }
}
