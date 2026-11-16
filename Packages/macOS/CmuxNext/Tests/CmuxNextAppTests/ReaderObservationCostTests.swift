import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextMobileHost
import CmuxNextSidebar
import Foundation
import Testing

/// What ONE change in ONE workspace costs two more readers that join an item of every workspace (or of every live
/// tab), in a session of 60 workspaces and in the person's 826 (`CMUX_TEST_SESSION_SIZES=large,real`): the items the
/// reader's work visits (``ObservationWork``), as ``ObservationCostTests`` counts them for the favicon table and Needs
/// you. Each reader passes the wake count of ``LargeSessionObservationTests`` (O5, O6): one tab's change wakes one
/// observation. The woken reader then asked `ObservedItems` for the item of EVERY listed workspace (or live tab) and
/// joined them all again.
///
/// What the count sees: the models a list pass of `ObservedItems` visits, each map of a model, and the keys the
/// reader's own join handles. NOT in the count, and still as large as its list after a change of the joined SET:
/// - the folders: the request to acpmux carries every folder (`_acpmux/workspace_roots_set` has no form for one
///   added or removed folder), so `MobileHostApproverSync` compares and encodes them all;
/// - the chat history: the Earlier window's spec names every chat an open tab shows (`exclude`), sorted, so one chat
///   more or less sorts and sends that list again (one key per open agent chat, not per workspace or tab).
/// Each test compares the reader's result with the join of everything after each step. Deterministic: no GUI, no timing.
@MainActor @Suite(.serialized)
struct ReaderObservationCostTests {
    /// The most items one change of one workspace may visit in the reader: its own map (1 or 2 evaluations) and the
    /// keys that changed (a folder or a chat before, one now). The same at 60 and at 826 workspaces.
    static let bound = 8

    /// The models a list pass of `ObservedItems` has visited.
    fileprivate static func listed(_ work: ObservationWork) -> Int { work.byStep["ObservedItems.list"] ?? 0 }

    /// The models `ObservedItems` has mapped.
    fileprivate static func mapped(_ work: ObservationWork) -> Int { work.byStep["ObservedItems.map"] ?? 0 }

    /// `MobileHostWorkspaceFolders` (the folders a phone's agent chat may start in): a `cd` in one terminal visits
    /// that terminal's workspace and the folders that came or went, whatever the session's size, and acpmux gets the
    /// folders of every workspace, each once.
    @Test(.timeLimit(.minutes(2)), arguments: SessionFixtureSize.arms)
    func oneFolderChangeVisitsItsWorkspaceOnly(size: SessionFixtureSize) async throws {
        let fixture = LargeSessionFixture(size)
        let work = ObservationWork()
        let folders = MobileHostWorkspaceFolders()
        var sent: [[String]] = []
        ObservationWork.$current.withValue(work) {
            folders.follow({ [store = fixture.store] in store.workspaces }, send: { sent.append($0) })
        }
        defer { folders.stop() }
        // The workspaces that start with a terminal: each lists one folder, its own.
        let owners = size.terminalWorkspaces
        await LargeSessionFixture.until { Self.listed(work) >= size.workspaces && sent.last?.count == owners.count }
        try #require(Self.listed(work) >= size.workspaces && sent.last?.count == owners.count,
                     "fixture: the reader never sent the folders of its workspace list")
        await LargeSessionFixture.drainMain()

        let terminals = fixture.tabs().filter { $0.tab.kind == .pty && $0.tab.resourceID?.rawValue.hasSuffix("_0") == true }
        try #require(terminals.count == owners.count)
        let (early, middle) = (terminals[1], terminals[terminals.count / 2])
        /// The folders of every workspace, each once: what the reader gave before it took one change.
        func whole() -> [String] {
            MobileHostWorkspaceFolders.joined(fixture.store.workspaces.map { MobileHostWorkspaceFolders.folders(of: $0) })
        }

        /// Makes one change of one terminal's folder, waits until its workspace was read again and acpmux has the
        /// folders of every workspace, and checks what that one change visited.
        func step(_ name: String, _ change: () -> Void) async {
            work.reset()
            change()
            await LargeSessionFixture.until { Self.mapped(work) >= 1 && Set(sent.last ?? []) == Set(whole()) }
            await LargeSessionFixture.drainMain()
            #expect(Self.mapped(work) >= 1, "fixture: no workspace was read again (the counter is not wired): \(name)")
            let all = whole()
            #expect(Set(sent.last ?? []) == Set(all), "\(name): acpmux does not have the folders of every workspace")
            #expect(sent.last?.count == all.count, "\(name): a folder was sent twice, or one is missing")
            #expect(work.count <= Self.bound,
                    "\(name): one folder change visited \(work.count) items \(work.byStep) in a session of \(size.workspaces) workspaces")
        }
        await step("a terminal goes to a new folder") { middle.tab.cwd = "/tmp/large/\(middle.workspace)/src" }
        await step("a terminal goes to a folder that another workspace lists") { early.tab.cwd = "/tmp/large/\(middle.workspace)/src" }
        await step("the first terminal leaves the shared folder: the other workspace still lists it") {
            middle.tab.cwd = "/tmp/large/\(middle.workspace)/docs"
        }
        await step("the last terminal leaves the shared folder") { early.tab.cwd = "/tmp/large/\(early.workspace)" }
    }

    /// The requests for the chat history's Earlier window: the chats each one leaves out (`exclude`).
    @MainActor final class EarlierRequests {
        var excludes: [[String]] = []
        func record(_ method: String, _ params: [String: any Sendable]) {
            guard method == "_acpmux/chats_window", params["window"] as? String == SidebarChatHistoryFeed.earlierWindow else { return }
            excludes.append(params["exclude"] as? [String] ?? [])
        }
    }
}

/// The chat history's case is a case of ``LargeSessionObservationTests``: it turns the session tree on in
/// `DesignSettings.shared` (one value for the process), as that suite's O2, O6 and O7 cases do, and that suite is
/// serialized. A case in a suite of its own would run beside them and turn the setting off under them. The count
/// holds in a serial run only (`--no-parallel`, as CI and the focused command run): a write of that setting by a
/// suite that runs beside this one wakes the list and adds a pass over every live tab to the count.
extension LargeSessionObservationTests {
    /// `SidebarChatHistoryFeed` (the session tree's Earlier list leaves out the chats open tabs show): a chat tab that
    /// moves to another session, or a session whose chat binding comes or goes, visits that one tab and the chats that
    /// came or went, whatever the session's size, and Earlier leaves out the chats of every live tab.
    @Test(.timeLimit(.minutes(2)), arguments: SessionFixtureSize.arms)
    func oneChatChangeVisitsItsTabOnly(size: SessionFixtureSize) async throws {
        let fixture = LargeSessionFixture(size)
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.sessionTree = true
        defer { DesignSettings.shared.sidebarSections = saved }
        let chats = fixture.chats()
        try #require(chats.count == size.chats)
        let (early, middle) = (chats[1], chats[chats.count / 2])
        let moved = "\(LargeSessionFixture.session(middle.workspace))-moved"
        /// A lane of this Mac's acpmux that continues the chat `claude-code:<session>` (nil: it names no chat yet).
        func lane(_ session: String, chat: Bool = true) -> AgentActivityLane {
            AgentActivityLane(id: session, name: session, title: session, peer: nil, parent: nil, state: .idle, since: nil,
                              error: nil, harness: "claude", chat: chat ? "claude-code:\(session)" : nil)
        }
        let lanes = AgentLaneStore()
        for chat in chats { lanes.set(LargeSessionFixture.session(chat.workspace), lane(LargeSessionFixture.session(chat.workspace))) }
        lanes.set(moved, lane(moved))
        let history = SidebarChatHistory(defaults: UserDefaults(suiteName: "reader-cost-chats-\(UUID().uuidString)")!)
        let windows = AcpmuxChatWindows()
        let requests = ReaderObservationCostTests.EarlierRequests()
        windows.connected(send: requests.record)
        let work = ObservationWork()
        let feed = SidebarChatHistoryFeed()
        ObservationWork.$current.withValue(work) {
            feed.start(liveTabs: { [store = fixture.store] in store.liveTabs }, localHost: LargeSessionFixture.host, open: { _ in },
                       windows: windows, lanes: lanes, history: history)
        }
        defer { withExtendedLifetime(feed) {} }
        /// The chats of every live tab, sorted: what the reader gave before it took one change.
        func whole() -> [String] {
            SidebarChatHistoryFeed.liveChats(fixture.store.liveTabs, lanes: lanes, localHost: LargeSessionFixture.host).sorted()
        }
        let tabs = fixture.store.liveTabs.count
        await LargeSessionFixture.until { ReaderObservationCostTests.listed(work) >= tabs && requests.excludes.last == whole() }
        try #require(ReaderObservationCostTests.listed(work) >= tabs && requests.excludes.last?.count == chats.count,
                     "fixture: Earlier never left out the \(chats.count) chats of the live tabs (\(requests.excludes.last?.count ?? -1))")
        await LargeSessionFixture.drainMain()

        /// Makes one change of one tab's chat, waits until that tab was read again and Earlier leaves out the chats of
        /// every live tab, and checks what that one change visited.
        func step(_ name: String, _ change: () -> Void) async {
            work.reset()
            change()
            await LargeSessionFixture.until { ReaderObservationCostTests.mapped(work) >= 1 && requests.excludes.last == whole() }
            await LargeSessionFixture.drainMain()
            #expect(ReaderObservationCostTests.mapped(work) >= 1,
                    "fixture: no tab was read again (the counter is not wired): \(name)")
            #expect(requests.excludes.last == whole(), "\(name): Earlier does not leave out the chats of every live tab")
            #expect(work.count <= ReaderObservationCostTests.bound,
                    "\(name): one chat change visited \(work.count) items \(work.byStep) in a session of \(tabs) tabs")
        }
        await step("a chat tab moves to another session") {
            let ref = AgentSessionRef(host: LargeSessionFixture.host, session: moved, harness: nil)
            middle.tab.conversation = ConversationTabRef(agentSession: ref)
        }
        #expect(requests.excludes.last?.contains("claude-code:\(moved)") == true)
        let session = LargeSessionFixture.session(early.workspace)
        await step("a session names no chat any more") { lanes.set(session, lane(session, chat: false)) }
        #expect(requests.excludes.last?.count == chats.count - 1)
        await step("the session names its chat again") { lanes.set(session, lane(session)) }
        #expect(requests.excludes.last?.count == chats.count)
    }
}
