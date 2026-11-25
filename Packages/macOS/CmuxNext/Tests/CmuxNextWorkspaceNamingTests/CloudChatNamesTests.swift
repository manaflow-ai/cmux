@testable import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWorkspaceNaming
import Foundation
import Observation
import Testing

/// cmux#55668 (Austin, NIGHTLY): a Cloud chat's workspace stayed "workspace-284" and its tab read the same, while a
/// local chat's took the chat's title. The turn store answered names only for this Mac's acpmux, which never lists a
/// Cloud machine's chats, and the namer read the Mac tab that shows a Cloud chat in place as that tab, not the chat.
/// The chat's page now notes its summary (``AgentTurnStateStore/noteRemote(_:host:machine:)``), and the reader names a
/// workspace after the chat its Mac tab shows: one path for local and Cloud chats.
@MainActor
struct CloudChatNamesTests {
    private static let localHost = "install:this-mac"
    private static let cloudHost = "install:cloud-vm"

    /// Workspace `name` whose one tab is an agent chat of `host` on session `session`.
    private static func workspace(_ store: DaemonStore, name: String, host: String, session: String?,
                                  surface: UInt64 = 1) throws -> (WorkspaceModel, TabModel) {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "about:blank", url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 284, key: nil, name: name, screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        return (workspace, try #require(workspace.screens.first?.panes.first?.tabs.first))
    }

    private static func reader(_ turns: AgentTurnStateStore, fronted: @escaping @MainActor (TabModel) -> TabModel? = { _ in nil })
        -> WorkspaceAutoNameReader {
        WorkspaceAutoNameReader(enabled: { true }, isNewTabPage: { _ in false }, livePage: { _ in nil }, incognitoTitle: { _ in nil },
                                terminal: { _ in .init(kind: .terminal, userName: nil, title: nil, pageTitle: nil, url: nil, cwd: nil) },
                                turns: turns, hold: WorkspaceAutoNameHold(), shown: fronted)
    }

    private static func turns() -> AgentTurnStateStore {
        let turns = AgentTurnStateStore()
        turns.localHost = localHost
        return turns
    }

    private static let summary: [String: Any] = ["sessionId": "acp_cloud", "title": "Fix the flaky login test", "titleSource": "generated"]

    @Test func aCloudChatReadsItsTitleOnceItsPageNotedIt() throws {
        let turns = Self.turns()
        let ref = AgentSessionRef(host: Self.cloudHost, session: "acp_cloud")
        #expect(turns.title(for: ref) == nil, "fixture: nothing of the Cloud chat is known before its page reads it")

        turns.noteRemote(Self.summary, host: Self.cloudHost, machine: "vm")
        #expect(turns.title(for: ref) == "Fix the flaky login test")
        #expect(turns.generatedTitle(for: ref) == "Fix the flaky login test")
        // Session ids are each daemon's own: the same id on this Mac or another machine is another chat.
        #expect(turns.title(for: AgentSessionRef(host: "install:other-vm", session: "acp_cloud")) == nil)
        #expect(turns.title(for: AgentSessionRef(host: Self.localHost, session: "acp_cloud")) == nil)
        // A rename there follows.
        turns.noteRemote(["sessionId": "acp_cloud", "title": "Login test fix", "titleSource": "generated"], host: Self.cloudHost, machine: "vm")
        #expect(turns.title(for: ref) == "Login test fix")
        // Names only: the Cloud chat's turn state is its machine's.
        turns.noteRemote(["sessionId": "acp_cloud", "title": "Login test fix", "indicator": "working"], host: Self.cloudHost, machine: "vm")
        #expect(turns.state(for: ref) == nil)
    }

    @Test func thisMacsOwnChatsAreNeverNotedFromAPage() {
        let turns = Self.turns()
        turns.noteRemote(Self.summary, host: Self.localHost, machine: "vm")
        #expect(turns.remoteRecordCount == 0)
        #expect(turns.title(for: AgentSessionRef(host: Self.localHost, session: "acp_cloud")) == nil)
    }

    @Test func aReaderOfTheUnknownChatReadsAgainOnceItIsNoted() {
        let turns = Self.turns()
        let ref = AgentSessionRef(host: Self.cloudHost, session: "acp_cloud")
        let changed = Changed()
        withObservationTracking { _ = turns.title(for: ref) } onChange: { changed.fired = true }
        turns.noteRemote(Self.summary, host: Self.cloudHost, machine: "vm")
        #expect(changed.fired, "the tab and row that read the chat before its page noted it redraw")
    }

    /// A Cloud chat in a Cloud machine's workspace (its tab's chat runs there): the row reads the chat's title, as a
    /// local chat's does.
    @Test func aCloudChatsWorkspaceTakesTheChatsTitle() throws {
        let turns = Self.turns()
        let (workspace, chat) = try Self.workspace(DaemonStore(), name: "workspace-284", host: Self.cloudHost, session: "acp_cloud")
        let reader = Self.reader(turns)
        #expect(reader.label(workspace, front: chat, work: nil) == nil, "fixture: the row reads workspace-284")
        turns.noteRemote(Self.summary, host: Self.cloudHost, machine: "vm")
        #expect(reader.label(workspace, front: chat, work: nil) == "Fix the flaky login test")
        #expect(reader.front(chat) == .chat(userName: nil, title: "Fix the flaky login test", generatedTitle: "Fix the flaky login test"))
    }

    /// The screenshot's case: this Mac's tab shows a Cloud chat in place (`CloudFrontedChats`). Its workspace on this
    /// Mac is named after that chat, as the tab strip already reads it, never after the Mac tab's own empty chat.
    @Test func aMacTabShowingACloudChatInPlaceNamesItsWorkspaceAfterThatChat() throws {
        let turns = Self.turns()
        let (workspace, macTab) = try Self.workspace(DaemonStore(), name: "workspace-284", host: Self.localHost, session: nil)
        let (_, cloudChat) = try Self.workspace(DaemonStore(), name: "workspace-9", host: Self.cloudHost, session: "acp_cloud", surface: 20)
        turns.noteRemote(Self.summary, host: Self.cloudHost, machine: "vm")

        #expect(Self.reader(turns).label(workspace, front: macTab, work: nil) == nil, "without the front, the row read workspace-284")
        let reader = Self.reader(turns) { $0 === macTab ? cloudChat : nil }
        #expect(reader.label(workspace, front: macTab, work: nil) == "Fix the flaky login test")
        #expect(reader.front(macTab) == .chat(userName: nil, title: "Fix the flaky login test", generatedTitle: "Fix the flaky login test"))
    }

    /// Another machine's summary is untrusted: its names are kept as plain one-line text, capped, and its icon (inline
    /// image bytes this Mac would decode) is never read.
    @Test func aRemoteChatsNamesArePlainTextAndItsIconIsNeverRead() {
        let turns = Self.turns()
        let ref = AgentSessionRef(host: Self.cloudHost, session: "acp_cloud")
        let spoof = "Fix login\u{202E}gpj.exe\u{200B}\nrm -rf ~\u{0007}"
        turns.noteRemote(["sessionId": "acp_cloud", "title": spoof, "titleSource": "generated", "displayName": "Mango\u{2066}\u{0000}",
                          "formerNames": ["old\u{2028}name"],
                          "icon": ["kind": "image", "mime": "image/png", "data": "iVBORw0KGgo=", "source": "session"]],
                         host: Self.cloudHost, machine: "vm")
        for name in [turns.title(for: ref), turns.generatedTitle(for: ref), turns.displayName(for: ref)] + turns.formerNames(for: ref) {
            let name = name ?? ""
            #expect(!name.unicodeScalars.contains { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) },
                    "\(name.debugDescription) keeps a control or invisible character")
        }
        #expect(turns.displayName(for: ref) == "Mango")
        #expect(turns.formerNames(for: ref) == ["old name"])
        #expect(turns.generatedTitle(for: ref)?.contains("gpj.exe") == true)
        #expect(turns.iconArt(for: ref) == nil, "a remote chat's icon is never decoded here")

        turns.noteRemote(["sessionId": "acp_cloud", "title": String(repeating: "a", count: 100_000), "titleSource": "generated"], host: Self.cloudHost, machine: "vm")
        #expect((turns.title(for: ref)?.count ?? 0) <= AgentTurnStateStore.remoteNameLimit)
        // A joined emoji keeps its joiner.
        #expect(AgentTurnStateStore.plainName("👩\u{200D}💻 ship it") == "👩\u{200D}💻 ship it")
    }

    @Test func aHostThatIsNotAMachinesOrCarriesControlsIsNeverNoted() {
        let turns = Self.turns()
        for host in ["vm", "install:" + String(repeating: "x", count: 300), "install:a\u{0000}b", "registry:a\u{202E}b"] {
            turns.noteRemote(Self.summary, host: host, machine: "vm")
        }
        #expect(turns.remoteRecordCount == 0)
        turns.noteRemote(Self.summary, host: "registry:cloud-vm", machine: "vm")
        #expect(turns.remoteRecordCount == 1)
    }

    @Test func theGlobalCapDropsTheHostNotingTheMostNeverEveryMachinesNames() {
        let turns = Self.turns()
        turns.noteRemote(Self.summary, host: Self.cloudHost, machine: "vm")
        for flood in 0..<8 {
            for chat in 0..<511 { turns.noteRemote(["sessionId": "acp_\(chat)", "title": "t"], host: "install:flood-\(flood)", machine: "flood") }
        }
        for chat in 0..<7 { turns.noteRemote(["sessionId": "acp_\(chat)", "title": "t"], host: Self.cloudHost, machine: "vm") }
        #expect(turns.remoteRecordCount == AgentTurnStateStore.remoteLimit, "fixture: the store is full")
        turns.noteRemote(["sessionId": "acp_new", "title": "t"], host: "install:flood-0", machine: "flood")
        #expect(turns.remoteRecordCount == AgentTurnStateStore.remoteLimit - 511 + 1)
        #expect(turns.title(for: AgentSessionRef(host: Self.cloudHost, session: "acp_cloud", harness: "claude")) != nil,
                "a flood on other hosts dropped this machine's names")
    }

    @Test func aFieldIsCappedByScalarsNotByCharacters() {
        // One grapheme of 10,000 combining marks: a cap by `Character` keeps all of it.
        let stacked = "a" + String(repeating: "\u{0301}", count: 10_000)
        #expect(AgentTurnStateStore.capped(stacked).unicodeScalars.count == AgentTurnStateStore.remoteFieldLimit)
    }

    @Test func aRemoteSessionIdThatIsTooLongOrCarriesControlsIsNeverNoted() {
        let turns = Self.turns()
        turns.noteRemote(["sessionId": String(repeating: "x", count: 300), "title": "t"], host: Self.cloudHost, machine: "vm")
        turns.noteRemote(["sessionId": "a\u{0000}b", "title": "t"], host: Self.cloudHost, machine: "vm")
        #expect(turns.remoteRecordCount == 0)
    }

    /// A machine names only its own chats: a host another machine noted first is refused, and the host two machines claim
    /// loses every name it had (a compromised VM naming another machine's chats).
    @Test func aHostIsOnlyEverOneMachines() {
        let turns = Self.turns()
        let ref = AgentSessionRef(host: Self.cloudHost, session: "acp_cloud")
        turns.noteRemote(Self.summary, host: Self.cloudHost, machine: "vm")
        turns.noteRemote(["sessionId": "acp_cloud", "title": "Pwned", "titleSource": "generated"], host: Self.cloudHost, machine: "evil-vm")
        #expect(turns.title(for: ref) == nil, "a contested host's names are dropped, never the second machine's")
        turns.noteRemote(Self.summary, host: Self.cloudHost, machine: "vm")
        #expect(turns.title(for: ref) == nil, "and it is noted from no machine again")
        #expect(turns.remoteRecordCount == 0)
    }

    @Test func nothingIsNotedBeforeThisMacKnowsItsOwnHost() {
        let turns = AgentTurnStateStore()
        turns.noteRemote(Self.summary, host: Self.localHost, machine: "vm")
        #expect(turns.remoteRecordCount == 0, "with no localHost, this Mac's own chats would read a remote's names")
    }

    /// Another machine's names never pick a name kept as the person's own: the workspace a person named at creation keeps it.
    @Test func namesAreRemoteOnlyForAChatAnotherMachineNamed() {
        let turns = Self.turns()
        let ref = AgentSessionRef(host: Self.cloudHost, session: "acp_cloud")
        #expect(!turns.namesAreRemote(ref))
        turns.noteRemote(["sessionId": "acp_cloud", "name": "My release", "title": "Pwned", "titleSource": "generated"],
                         host: Self.cloudHost, machine: "vm")
        #expect(turns.namesAreRemote(ref))
        #expect(!turns.namesAreRemote(AgentSessionRef(host: Self.localHost, session: "acp_cloud")))
    }

    @Test func plainNameDropsInvisibleAndStackedCharacters() {
        #expect(AgentTurnStateStore.plainName("a\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}b") == "a\u{0301}\u{0301}b")
        #expect(AgentTurnStateStore.plainName("\u{3164}\u{115F}\u{2800}\u{034F}\u{FE00}") == nil)
        #expect(AgentTurnStateStore.plainName("ab\u{200D}cd") == "abcd", "a joiner outside an emoji sequence never shows")
        #expect(AgentTurnStateStore.plainName("❤\u{FE0F} 1\u{FE0F}\u{20E3}") == "❤\u{FE0F} 1\u{FE0F}\u{20E3}")
        #expect(AgentTurnStateStore.plainName("\u{202E}evil\u{202C}\r\n\tname  ") == "evil name")
    }

    /// Nested in a `@MainActor` suite it would be main-actor isolated, so `onChange` (a Sendable closure) could not set it.
    private final class Changed: @unchecked Sendable { nonisolated(unsafe) var fired = false }
}
