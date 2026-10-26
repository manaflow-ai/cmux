import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextWorkspaceNaming
import Testing

/// Automatic workspace names follow the focused chat's generated title. The
/// same title causes no mutation, and a manual rename or a stale observation
/// cannot submit a name for another chat.
@MainActor
struct WorkspaceAutoNamerTests {
    private static let host = "install:auto-name-namer"

    private static func chat(_ surface: UInt64 = 1, session: String? = "s1") -> TabSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
        return tab
    }

    @MainActor
    private final class Fixture {
        let turns = AgentTurnStateStore()
        let workspace: WorkspaceModel
        var selectedTab: String?
        var enabled = true
        var isNewTabPage = false
        var sent: [String] = []
        var defersSend = false
        var queued: [(name: String, maySend: @MainActor @Sendable () -> Bool)] = []

        init(name: String = "workspace-7", source: WorkspaceNameSource = .auto,
             revision: UInt64 = 0, tabs: [TabSnapshot] = [WorkspaceAutoNamerTests.chat()]) {
            let snapshot = Self.snapshot(name: name, source: source, revision: revision, tabs: tabs)
            workspace = WorkspaceModel(snapshot)
            turns.localHost = WorkspaceAutoNamerTests.host
        }

        private static func snapshot(name: String, source: WorkspaceNameSource, revision: UInt64,
                                     tabs: [TabSnapshot]) -> WorkspaceSnapshot {
            let pane = PaneSnapshot(id: 1, tabs: tabs)
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
            return WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "auto-name-test"), name: name,
                                     nameSource: source, nameRevision: revision, screens: [screen])
        }

        func update(name: String? = nil, source: WorkspaceNameSource? = nil, revision: UInt64? = nil,
                    tabs: [TabSnapshot] = [WorkspaceAutoNamerTests.chat()]) {
            workspace.update(Self.snapshot(name: name ?? workspace.name, source: source ?? workspace.nameSource,
                                           revision: revision ?? workspace.nameRevision, tabs: tabs))
        }

        func title(_ title: String, session: String = "s1", source: String = "generated") {
            let summary: [String: Any] = ["title": title, "titleSource": source]
            turns.apply(session: session, state: nil, lastMessage: nil, muted: false,
                        title: AgentTurnStates.title(summary),
                        generatedTitle: AgentTurnStates.title(summary, includingPrompt: false), detail: nil)
        }

        lazy var namer: WorkspaceAutoNamer = {
            let reader = WorkspaceAutoNameReader(
                enabled: { [weak self] in self?.enabled ?? false },
                isNewTabPage: { [weak self] _ in self?.isNewTabPage ?? true },
                livePage: { _ in nil }, incognitoTitle: { _ in nil },
                terminal: { tab in .init(kind: .terminal, userName: nil, title: tab.titleText,
                                         pageTitle: nil, url: nil, cwd: tab.cwd) },
                turns: turns, hold: WorkspaceAutoNameHold())
            return WorkspaceAutoNamer(
                names: reader,
                workspaces: { [weak self] in
                    guard let self else { return [] }
                    return [.init(machineID: DaemonCommandScope.localMachine, workspace: workspace,
                                  supportsNameSource: true, daemonGeneration: nil,
                                  nameSource: workspace.nameSource, nameRevision: workspace.nameRevision)]
                },
                selection: { [weak self] _, _ in self?.selectedTab },
                rename: { [weak self] _, name, maySend in
                    guard let self else { return false }
                    if defersSend { queued.append((name, maySend)); return true }
                    guard maySend() else { return false }
                    sent.append(name)
                    return true
                })
        }()
    }

    @Test func aDefaultWorkspacePersistsItsFirstGeneratedTitleOncePerRevision() {
        let fixture = Fixture()
        fixture.title("First title")
        let queued = fixture.namer.pending()
        #expect(queued.first?.name == "First title")
        fixture.namer.apply(queued)
        fixture.namer.apply(queued)
        #expect(fixture.sent == ["First title"])
        fixture.update(name: "First title", revision: 1)
        #expect(fixture.namer.pending().isEmpty)
    }

    @Test func anAutomaticWorkspaceFollowsLaterGeneratedTitles() {
        let fixture = Fixture(name: "First title", revision: 1)
        fixture.title("Second title")
        fixture.namer.apply(fixture.namer.pending())
        #expect(fixture.sent == ["Second title"])

        fixture.update(name: "Second title", revision: 2)
        fixture.title("Third title")
        fixture.namer.apply(fixture.namer.pending())
        #expect(fixture.sent == ["Second title", "Third title"])
    }

    @Test func selectingAnotherChatUpdatesAnAutomaticWorkspaceName() throws {
        let fixture = Fixture(name: "First title", revision: 1, tabs: [Self.chat(), Self.chat(2, session: "s2")])
        fixture.title("First title")
        fixture.title("Second chat", session: "s2")
        #expect(fixture.namer.pending().isEmpty)
        fixture.selectedTab = try #require(fixture.workspace.screens.first?.panes.first?.tabs.last?.id)
        fixture.namer.apply(fixture.namer.pending())
        #expect(fixture.sent == ["Second chat"])
    }

    @Test func aPromptFallbackNeverBecomesAPersistedName() {
        let fixture = Fixture(name: "First title", revision: 1)
        fixture.title("Look at this failing build", source: "prompt")
        #expect(fixture.namer.pending().isEmpty)
        fixture.title("Build repair", source: "generated")
        #expect(fixture.namer.pending().first?.name == "Build repair")
    }

    @Test func aNewTabStartsNamingOnlyAfterItsAgentSessionIsBound() {
        let fixture = Fixture(tabs: [Self.chat(session: nil)])
        fixture.isNewTabPage = true
        fixture.title("First title")
        #expect(fixture.namer.pending().isEmpty)
        fixture.update(tabs: [Self.chat(session: "s1")])
        fixture.isNewTabPage = false
        #expect(fixture.namer.pending().first?.name == "First title")
    }

    @Test func aQueuedRenameIsDroppedWhenTheFocusedChatChanges() throws {
        let fixture = Fixture(name: "Old title", tabs: [Self.chat(), Self.chat(2, session: "s2")])
        fixture.title("Chat one")
        fixture.title("Chat two", session: "s2")
        let queued = fixture.namer.pending()
        #expect(queued.first?.name == "Chat one")
        fixture.selectedTab = try #require(fixture.workspace.screens.first?.panes.first?.tabs.last?.id)
        fixture.namer.apply(queued)
        #expect(fixture.sent.isEmpty)
        fixture.namer.apply(fixture.namer.pending())
        #expect(fixture.sent == ["Chat two"])
    }

    @Test func aQueuedRenameIsDroppedWhenTheSameTabBindsAnotherSession() {
        let fixture = Fixture(name: "Old title")
        fixture.title("Same generated title")
        fixture.title("Same generated title", session: "s2")
        let queued = fixture.namer.pending()
        #expect(queued.count == 1)
        fixture.update(tabs: [Self.chat(session: "s2")])
        fixture.namer.apply(queued)
        #expect(fixture.sent.isEmpty)
    }

    @Test func aQueuedRenameIsDroppedWhenTheChatTitleChanges() {
        let fixture = Fixture(name: "Old title")
        fixture.title("Chat one")
        let queued = fixture.namer.pending()
        #expect(queued.count == 1)
        fixture.title("Chat one updated")
        fixture.namer.apply(queued)
        #expect(fixture.sent.isEmpty)
    }

    @Test func aQueuedRenameIsDroppedAfterAUserRename() {
        let fixture = Fixture(name: "Old title")
        fixture.title("Chat one")
        let queued = fixture.namer.pending()
        #expect(queued.count == 1)
        fixture.update(name: "Mine", source: .user, revision: 1)
        fixture.namer.apply(queued)
        #expect(fixture.sent.isEmpty)
        #expect(fixture.namer.pending().isEmpty)
        fixture.title("Later title")
        #expect(fixture.namer.pending().isEmpty)
    }

    @Test func aDeferredSendRechecksTheFocusedChatAndReleasesItsSubmission() throws {
        let fixture = Fixture(name: "Old title", tabs: [Self.chat(), Self.chat(2, session: "s2")])
        fixture.title("Chat one")
        fixture.title("Chat two", session: "s2")
        fixture.defersSend = true
        fixture.namer.apply(fixture.namer.pending())
        #expect(fixture.queued.count == 1)
        fixture.selectedTab = try #require(fixture.workspace.screens.first?.panes.first?.tabs.last?.id)
        let deferred = try #require(fixture.queued.popLast())
        #expect(!deferred.maySend())
        #expect(fixture.sent.isEmpty)

        // Switching back at the same daemon revision retries the cancelled name.
        fixture.selectedTab = nil
        fixture.defersSend = false
        fixture.namer.apply(fixture.namer.pending())
        #expect(fixture.sent == ["Chat one"])
    }

    @Test func aQueuedRenameIsDroppedWhenTheSettingTurnsOff() {
        let fixture = Fixture()
        fixture.title("First title")
        let queued = fixture.namer.pending()
        #expect(queued.count == 1)
        fixture.enabled = false
        fixture.namer.apply(queued)
        #expect(fixture.sent.isEmpty)
        #expect(fixture.namer.pending().isEmpty)
    }
}
