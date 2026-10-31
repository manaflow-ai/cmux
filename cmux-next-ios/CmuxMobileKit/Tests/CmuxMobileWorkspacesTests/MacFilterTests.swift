import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

@MainActor @Suite struct MacFilterTests {
    let suite = "cmuxMobile.tests.macfilter.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    let team = Team(id: "t1", name: "One", macs: [
        MacDevice(id: "a", name: "Studio", isOnline: true),
        MacDevice(id: "b", name: "Air", isOnline: false),
    ])
    let other = Team(id: "t2", name: "Two", macs: [MacDevice(id: "c", name: "mini", isOnline: true)])

    @Test func defaultsToAllMacs() {
        let filter = MacFilter(defaults: defaults)
        #expect(filter.scope(in: team) == .all)
        #expect(filter.scope(in: nil) == .all)
    }

    @Test func remembersTheMacPerTeamAcrossLaunches() {
        let filter = MacFilter(defaults: defaults)
        filter.select(.mac("b"), in: "t1")
        filter.select(.mac("c"), in: "t2")
        let relaunched = MacFilter(defaults: defaults)
        #expect(relaunched.scope(in: team) == .mac("b"))
        #expect(relaunched.scope(in: other) == .mac("c"))
        relaunched.select(.all, in: "t1")
        #expect(MacFilter(defaults: defaults).scope(in: team) == .all)
        #expect(MacFilter(defaults: defaults).scope(in: other) == .mac("c"))
    }

    @Test func aMacThatLeftTheTeamReadsAsAllMacs() {
        let filter = MacFilter(defaults: defaults)
        filter.select(.mac("b"), in: "t1")
        var shrunk = team
        shrunk.macs.removeAll { $0.id == "b" }
        #expect(filter.scope(in: shrunk) == .all)
        // A Mac from another team never applies here.
        filter.select(.mac("c"), in: "t1")
        #expect(filter.scope(in: team) == .all)
    }

    @Test func theFilterIsAnAccountPreference() {
        #expect(AppStore.isAccountPreference(MacFilter.keyPrefix + "t1"))
    }
}

@Suite struct WorkspaceInboxTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let macs = [
        MacDevice(id: "a", name: "Studio", isOnline: true),
        MacDevice(id: "off", name: "Laptop", isOnline: false, lastSeenAt: Date(timeIntervalSince1970: 1_799_990_000)),
        MacDevice(id: "b", name: "mini", isOnline: true),
    ]

    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    func ws(_ id: String, _ mac: String, _ minutes: Double, branch: String? = nil, needs: Bool = false, working: Bool = false,
            unread: Bool = false, tabs: [WorkspaceTab] = []) -> Workspace {
        Workspace(id: id, macID: mac, title: id, directory: "~/src/\(id)", branch: branch, tabs: tabs, lastActivityAt: ago(minutes),
                  needsAttention: needs, isWorking: working, hasUnread: unread)
    }

    var items: [Workspace] {
        [
            ws("a-idle", "a", 120, branch: "main"),
            ws("a-waiting-old", "a", 30, needs: true),
            ws("b-working", "b", 5, working: true),
            ws("a-waiting-new", "a", 1, needs: true, working: true),
            ws("off-1", "off", 10, branch: "feat-x", needs: true),
            ws("off-2", "off", 300),
            ws("b-done", "b", 20, unread: true),
            ws("gone", "left-the-team", 0),
        ]
    }

    func inbox(_ scope: MacScope = .all, query: String = "", context: WorkspaceInbox.Context = .init(),
               workspaces: [Workspace]? = nil) -> WorkspaceInbox {
        WorkspaceInbox(scope: scope, macs: macs, workspaces: workspaces ?? items, query: query, context: context)
    }

    @Test func needsYouIsPinnedThenRecentNewestFirstThenOfflineFolded() {
        let all = inbox()
        #expect(all.needsYou.map(\.id) == ["a-waiting-new", "a-waiting-old"])
        // Working and done rows stay in time order; they do not jump.
        #expect(all.recent.map(\.id) == ["b-working", "b-done", "a-idle"])
        #expect(all.folds.map(\.id) == ["off"])
        #expect(all.folds[0].reason == .offline)
        #expect(all.folds[0].workspaces.map(\.id) == ["off-1", "off-2"])
        #expect(!all.folds[0].isForcedOpen)
        // A workspace on an offline Mac never reads as needing you.
        #expect(all.status(items[4]) == .offline)
        #expect(all.showsMacNames)
        #expect(!all.allAsleep && !all.isEmpty)
    }

    @Test func statusPriority() {
        let base = ws("x", "a", 1, needs: true, working: true, unread: true)
        #expect(WorkspaceStatus(base, isOnline: true, isPending: true) == .creating)
        #expect(WorkspaceStatus(base, isOnline: false) == .offline)
        #expect(WorkspaceStatus(base, isOnline: true) == .needsYou)
        var next = base
        next.needsAttention = false
        #expect(WorkspaceStatus(next, isOnline: true) == .working)
        next.isWorking = false
        #expect(WorkspaceStatus(next, isOnline: true) == .done)
        // Opened here after its last activity: no longer Done, until newer activity.
        #expect(WorkspaceStatus(next, isOnline: true, seenAt: now) == .idle)
        #expect(WorkspaceStatus(next, isOnline: true, seenAt: ago(5)) == .done)
        next.hasUnread = false
        #expect(WorkspaceStatus(next, isOnline: true) == .idle)
        #expect(WorkspaceStatus.creating < .needsYou && WorkspaceStatus.needsYou < .working && WorkspaceStatus.done < .idle)
    }

    @Test func filterToOneMac() {
        let b = inbox(.mac("b"))
        #expect(b.needsYou.isEmpty)
        #expect(b.recent.map(\.id) == ["b-working", "b-done"])
        #expect(b.folds.isEmpty)
        #expect(!b.showsMacNames)
        // An offline Mac's rows are always open when it is the filter.
        let off = inbox(.mac("off"))
        #expect(off.needsYou.isEmpty && off.recent.isEmpty)
        #expect(off.folds.map(\.id) == ["off"])
        #expect(off.folds[0].isForcedOpen)
        // A Mac that left the team reads as All.
        #expect(inbox(.mac("zzz")).scope == .all)
        #expect(inbox(.mac("b"), workspaces: []).isEmpty)
    }

    @Test func searchMatchesNameBranchDirectoryMacAndAgentTasks() {
        let tabbed = items + [ws("tasked", "a", 3, tabs: [
            WorkspaceTab(id: "t1", kind: .agent, title: "Claude", subtitle: "Refactor transport", harness: "claude"),
        ])]
        func ids(_ query: String, _ scope: MacScope = .all) -> [String] {
            let result = inbox(scope, query: query, workspaces: tabbed)
            return (result.needsYou + result.recent + result.folds.flatMap(\.workspaces)).map(\.id)
        }
        #expect(ids("WAITING") == ["a-waiting-new", "a-waiting-old"])
        #expect(ids("feat-x") == ["off-1"])
        #expect(ids("src/b-d") == ["b-done"])
        #expect(ids("mini") == ["b-working", "b-done"])
        #expect(ids("transport") == ["tasked"])
        #expect(ids("done", .mac("a")).isEmpty)
        #expect(ids("   ") == ids(""))
        #expect(ids("nothing").isEmpty)
        // Offline matches are shown open while searching.
        #expect(inbox(query: "off").folds.first?.isForcedOpen == true)
    }

    @Test func everyMacAsleepOpensTheirFolds() {
        let asleep = [MacDevice(id: "off", name: "Laptop", isOnline: false)]
        let result = WorkspaceInbox(scope: .all, macs: asleep, workspaces: items)
        #expect(result.allAsleep)
        #expect(result.needsYou.isEmpty && result.recent.isEmpty)
        #expect(result.folds.first?.isForcedOpen == true)
    }

    @Test func rowsWithoutAnActivityTimeGoLastInTheMacsFocusOrder() {
        var first = ws("seen-first", "a", 0)
        first.hasActivityTime = false
        first.focusOrder = 1
        var focused = ws("focused", "a", 0)
        focused.hasActivityTime = false
        focused.focusOrder = 9
        let timed = ws("timed", "a", 50)
        let result = inbox(workspaces: [first, focused, timed])
        #expect(result.recent.map(\.id) == ["timed", "focused", "seen-first"])
    }

    @Test func liveListStates() {
        func ctx(_ phases: [String: MacDataMachine.Phase]) -> WorkspaceInbox.Context { .init(phases: phases) }
        // Linked to "a", dialing, last-known rows cached: shown dimmed (stale)
        // with no agent state, and marked updating.
        let cached = inbox(context: ctx(["a": .cached(.connecting)]))
        #expect(cached.isUpdating)
        #expect(!cached.isLoading)
        #expect(cached.needsYou.isEmpty)
        #expect(cached.recent.filter { $0.macID == "a" }.allSatisfy { cached.stale.contains($0.id) && cached.status($0) == .idle })
        // "b" is online but nothing dials it: one line, no stale rows.
        #expect(cached.recent.allSatisfy { $0.macID == "a" })
        #expect(cached.folds.map(\.id) == ["off", "b"])
        #expect(cached.folds[1].reason == .notConnected)
        #expect(cached.folds[1].workspaces.isEmpty)
        // A failed dial with nothing known: a line that retries.
        let failed = inbox(context: ctx(["a": .live, "b": .failed("timed out")]))
        #expect(failed.folds.last?.reason == .failed("timed out"))
        #expect(failed.needsYou.map(\.id) == ["a-waiting-new", "a-waiting-old"])
        #expect(failed.stale.isEmpty)
        // Nothing known yet: a loading state, not "No workspaces".
        let empty = inbox(.mac("a"), context: ctx(["a": .loading]), workspaces: [])
        #expect(empty.isLoading)
        // Filtered to the unlinked Mac: no fold line, the empty state explains.
        let unlinked = inbox(.mac("b"), context: ctx(["a": .live]))
        #expect(unlinked.isEmpty)
        // A Mac whose list is live is not updating.
        #expect(!inbox(.mac("a"), context: ctx(["a": .live])).isUpdating)
        #expect(WorkspaceInbox.ListState(.empty) == .live)
        #expect(WorkspaceInbox.ListState(.cached(.idle)) == .cached(updating: false))
    }

    @Test func pendingRowsShowAsCreatingAtTheTop() {
        let pending = Workspace(id: "new", macID: "a", title: "New Workspace", directory: "~", tabs: [], lastActivityAt: now)
        let result = inbox(context: .init(pending: ["new"]), workspaces: items + [pending])
        #expect(result.recent.first?.id == "new")
        #expect(result.status(pending) == .creating)
    }

    @Test func statusNamesTheWaitingTab() {
        let tabs = [
            WorkspaceTab(id: "t1", kind: .agent, title: "Claude", subtitle: "Docs pass", harness: "claude", agentStatus: .working),
            WorkspaceTab(id: "t2", kind: .terminal, title: "zsh"),
            WorkspaceTab(id: "t3", kind: .agent, title: "Fix the build", harness: "codex", agentStatus: .waiting),
        ]
        let w = ws("x", "a", 1, needs: true, tabs: tabs)
        #expect(w.agentTab(for: .needsYou)?.id == "t3")
        #expect(w.agentTab(for: .working)?.id == "t1")
        #expect(w.agentTab(for: .done)?.id == "t1")
        #expect(tabs[2].agentName == "Codex" && tabs[2].task == "Fix the build")
        // A tab titled with only the agent's name names its subtitle as the task.
        #expect(tabs[0].task == "Docs pass")
        #expect(WorkspaceTab(id: "c", kind: .agent, title: "Claude", harness: "claude").task == nil)
        // No per-tab state from the Mac: the first agent tab.
        let plain = ws("y", "a", 1, needs: true, tabs: [tabs[1], WorkspaceTab(id: "t4", kind: .agent, title: "Agent", harness: "goose")])
        #expect(plain.agentTab(for: .needsYou)?.id == "t4")
        #expect(plain.agentTab(for: .needsYou)?.agentName == "Goose")
        #expect(ws("z", "a", 1).agentTab(for: .needsYou) == nil)
    }

    @Test func filterMenuPutsOnlineMacsFirst() {
        #expect(MacScope.menuOrder(macs).map(\.id) == ["a", "b", "off"])
    }

    @Test func newWorkspaceTargetsTheChosenMac() {
        let available = macs.filter(\.isOnline)
        // The chosen Mac wins over the preferred one.
        #expect(MacScope.mac("b").newWorkspaceMac(available: available, fallback: available[0])?.id == "b")
        // An offline chosen Mac cannot take one: no silent fallback to another Mac.
        #expect(MacScope.mac("off").newWorkspaceMac(available: available, fallback: available[0]) == nil)
        #expect(MacScope.all.newWorkspaceMac(available: available, fallback: available[1])?.id == "b")
    }
}

/// Opening: a needs-you workspace on its waiting tab, else the last tab
/// used here, else the Mac's active tab, else the first.
@MainActor @Suite struct OpeningTabTests {
    @Test func mockOpensTheWaitingTabAndTheMacsActiveTab() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let ghostty = try #require(store.workspace(id: "ws-ghostty"))
        let status = WorkspaceStatus(ghostty, isOnline: true)
        #expect(status == .needsYou)
        // The waiting agent is the second tab; the list notes it before the push.
        #expect(ghostty.agentTab(for: status)?.id == "t-gh-codex")
        let ios = try #require(store.workspace(id: "ws-ios"))
        #expect(store.openingTab(for: ios)?.id == "t-ios-build")
        store.noteOpened(tabID: "t-ios-claude", in: "ws-ios")
        #expect(store.openingTab(for: ios)?.id == "t-ios-claude")
    }

    @Test func openingClearsDone() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let fleet = try #require(store.workspace(id: "ws-infra"))
        #expect(WorkspaceStatus(fleet, isOnline: true, seenAt: store.seenAt[fleet.id]) == .done)
        store.markSeen(fleet.id)
        #expect(WorkspaceStatus(fleet, isOnline: true, seenAt: store.seenAt[fleet.id]) == .idle)
    }

    @Test func mockHasTheRealisticMix() {
        let store = AppStore.mock(tabMemory: .inMemory())
        let team = store.activeTeam!
        #expect(team.macs.count == 2)
        let result = WorkspaceInbox(scope: .all, macs: team.macs, workspaces: store.workspaces)
        #expect(result.needsYou.map(\.id) == ["ws-cmux", "ws-ghostty"])
        #expect(Set(result.recent.map { result.status($0) }) == [.working, .done, .idle])
        #expect(result.folds.map(\.mac.id) == ["mbp"])
    }
}

@MainActor @Suite struct WorkspaceManagementTests {
    func make() -> (AppStore, MockWorkspaceCreationBackend, WorkspaceCreator) {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let suite = UserDefaults(suiteName: "cmuxMobile.tests.manage.\(UUID().uuidString)")!
        return (store, backend, WorkspaceCreator(store: store, backend: backend, defaults: suite))
    }

    @Test func renameAndCloseApplyAtOnce() async throws {
        let (store, _, creator) = make()
        let ws = try #require(store.workspace(id: "ws-web"))
        creator.rename(ws, to: "  site  ")
        #expect(store.workspace(id: "ws-web")?.title == "site")
        creator.close(try #require(store.workspace(id: "ws-web")))
        #expect(store.workspace(id: "ws-web") == nil)
        await creator.settle()
        #expect(store.workspace(id: "ws-web") == nil)
    }

    @Test func aRefusalUndoesTheChange() async throws {
        let (store, backend, creator) = make()
        var failures: [String] = []
        creator.onManageFailure = { _, what, _ in failures.append(what) }
        let ws = try #require(store.workspace(id: "ws-web"))
        let index = try #require(store.workspaces.firstIndex { $0.id == "ws-web" })
        backend.failNext = "no"
        creator.rename(ws, to: "site")
        await creator.settle()
        #expect(store.workspace(id: "ws-web")?.title == "cmux.com")
        backend.failNext = "no"
        creator.close(ws)
        await creator.settle()
        #expect(store.workspaces.firstIndex { $0.id == "ws-web" } == index)
        #expect(failures == ["Couldn't rename cmux.com", "Couldn't close cmux.com"])
    }

    /// Duplicate Workspace (the Mac's row menu): the Mac makes the copy; a refusal is one line.
    @Test func duplicateWorkspace() async throws {
        let (store, backend, creator) = make()
        var failures: [String] = []
        creator.onManageFailure = { _, what, _ in failures.append(what) }
        let ws = try #require(store.workspace(id: "ws-web"))
        #expect(creator.canDuplicate(ws))
        creator.duplicate(ws)
        await creator.settle()
        #expect(backend.duplicated == ["ws-web"])
        backend.failNext = "no"
        creator.duplicate(ws)
        await creator.settle()
        #expect(failures == ["Couldn't duplicate cmux.com"])
        // An offline Mac's workspace and Home have no duplicate.
        let offline = try #require(store.workspace(id: "ws-notes"))
        #expect(!creator.canDuplicate(offline))
        var home = ws
        home.isHome = true
        #expect(!creator.canDuplicate(home))
        creator.duplicate(home)
        await creator.settle()
        #expect(backend.duplicated == ["ws-web"])
    }

    @Test func offlineMacsAndBlankNamesAreRefused() throws {
        let (store, _, creator) = make()
        let offline = try #require(store.workspace(id: "ws-notes"))
        #expect(!creator.canManage(offline))
        creator.close(offline)
        #expect(store.workspace(id: "ws-notes") != nil)
        let ws = try #require(store.workspace(id: "ws-web"))
        creator.rename(ws, to: "   ")
        #expect(store.workspace(id: "ws-web")?.title == "cmux.com")
    }
}

/// verify/e2e-matrix.md #2: choosing a Mac in the filter (or opening one of
/// its workspaces) links it, and the list never says "can't take new
/// workspaces" while it is still linking that Mac.
@MainActor @Suite struct MacSelectionLinkTests {
    let macs = [
        MacDevice(id: "a", name: "Studio", isOnline: true),
        MacDevice(id: "b", name: "MacBook Pro", isOnline: true),
        MacDevice(id: "c", name: "Air", isOnline: false),
    ]

    @Test func choosingAnOnlineMacLinksIt() throws {
        let suite = "cmuxMobile.tests.maclink.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let team = Team(id: "t1", name: "One", macs: macs)
        let filter = MacFilter(defaults: defaults)
        #expect(filter.scope(in: team).macToLink(in: macs) == nil)
        filter.select(.mac("b"), in: "t1")
        #expect(filter.scope(in: team).macToLink(in: macs) == "b")
        // A relaunch with the choice remembered links it again.
        #expect(MacFilter(defaults: defaults).scope(in: team).macToLink(in: macs) == "b")
        // Nothing to dial: an offline Mac, a Mac not in the team, All Macs.
        #expect(MacScope.mac("c").macToLink(in: macs) == nil)
        #expect(MacScope.mac("gone").macToLink(in: macs) == nil)
        #expect(MacScope.all.macToLink(in: macs) == nil)
    }

    @Test func theChosenMacComingOnlineLinksIt() {
        var team = macs
        #expect(MacScope.mac("c").macToLink(in: team) == nil)
        team[2].isOnline = true
        #expect(MacScope.mac("c").macToLink(in: team) == "c")
    }

    @Test func openingAWorkspaceLinksItsMac() {
        let ws = Workspace(id: "w", macID: "b", title: "w", directory: "~", tabs: [], lastActivityAt: Date())
        #expect(MacScope.macToLink(opening: ws, in: macs) == "b")
        let asleep = Workspace(id: "x", macID: "c", title: "x", directory: "~", tabs: [], lastActivityAt: Date())
        #expect(MacScope.macToLink(opening: asleep, in: macs) == nil)
    }

    @Test func aMacBeingLinkedSaysConnecting() {
        func state(_ list: WorkspaceInbox.ListState, _ connection: MacConnection?, online: Bool = true,
                   reach: MacReach = .linkTarget, canCreate: Bool = false, live: Bool = true) -> MacEmptyState {
            MacEmptyState.resolve(isOnline: online, list: list, connection: connection, tracksLive: live,
                                  reach: reach, canCreate: canCreate)
        }
        // The e2e case: last-known "no rows" for a Mac the link is not on.
        #expect(state(.cached(updating: false), nil) == .connecting)
        #expect(state(.cached(updating: true), .connecting) == .connecting)
        #expect(state(.notConnected, nil) == .connecting)
        #expect(state(.loading, .connecting) == .connecting)
        // Linked, but its list has not come over this link yet.
        #expect(state(.cached(updating: false), .connected) == .connecting)
        // The Mac answered.
        #expect(state(.live, .connected, canCreate: true) == .empty(canCreate: true))
        #expect(state(.live, .connected) == .empty(canCreate: false))
        // Failures and sleep say so.
        #expect(state(.failed("timed out"), nil) == .failed("timed out"))
        #expect(state(.cached(updating: false), .failed("timed out")) == .failed("timed out"))
        #expect(state(.live, nil, online: false) == .offline)
        // Review M5: the link is on another Mac (or on none, say the team start failed):
        // never "Connecting…" with no way out, but Connect.
        #expect(state(.notConnected, nil, reach: .elsewhere) == .notConnected)
        #expect(state(.cached(updating: false), nil, reach: .elsewhere) == .notConnected)
        #expect(state(.loading, nil, reach: .elsewhere) == .notConnected)
        #expect(state(.cached(updating: false), .connecting, reach: .elsewhere) == .notConnected)
        // Review m11: a teammate's Mac has no Connect that does nothing.
        #expect(state(.notConnected, nil, reach: .othersMac) == .othersMac)
        #expect(state(.live, nil, reach: .othersMac) == .othersMac)
        // Mock mode (no live link): nothing to move.
        #expect(state(.notConnected, nil, reach: .none) == .notConnected)
        // Mock mode: every list is the Mac's own.
        #expect(state(.live, nil, canCreate: true, live: false) == .empty(canCreate: true))
    }
}
