import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A remote Priority row behaves like this Mac's: an idle one leaves after a day, a read or
/// snooze mark holds across a relaunch, a closed tab drops off and loses its marks once its
/// machine is live, a machine that is not connected keeps its marks, opening a row reveals the
/// tab on the machine whose row it is, and archive leaves another machine's chat alone. The view
/// builds its chats once per change.
@MainActor @Suite(.serialized)
struct SidebarPriorityRemoteRowsTests {
    typealias Remote = SidebarPriorityRemoteChatsTests

    /// Counts how often the feed asks for the other machines.
    @MainActor final class Builds {
        var count = 0
    }

    /// Whether the busy machine is listed.
    @MainActor final class Flag {
        var on = false
    }

    static func connected(_ store: DaemonStore) throws {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"priority-remote-rows","generation":"g1"}"#
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
    }

    static func tree(_ tabs: [TabSnapshot]) -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: tabs)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    static func chats(_ machines: @escaping @MainActor () -> [SidebarPriorityMachine], marks: AgentPriorityMarks = AgentPriorityMarks(defaults: nil),
                      builds: Builds = Builds()) -> AgentPriorityChats {
        AgentPriorityChats(marks: marks, stores: [AgentLaneStore()],
                           machines: .init(remote: { builds.count += 1; return machines() }, peer: { _ in nil }, local: { nil }),
                           checksFailing: { _ in false }) { _, _ in }
    }

    /// The feed of `chats`, running on a sidebar as a window's does.
    static func running(_ chats: AgentPriorityChats) -> (feed: SidebarPriorityFeed, task: Task<Void, Never>) {
        let feed = SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { true }),
                                       hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: { _ in }, toggleShown: {}), chats: chats)
        let view = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        return (feed, feed.start(view))
    }

    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aRemoteIdleRowAgesOutLikeThisMacsIdleRows() throws {
        var old = Remote.chatTab(2, session: "vm-read", host: "install:vm", title: "Read", notice: (52, .info, unread: false))
        old.notification?.createdAtMs = UInt64((Date().timeIntervalSince1970 - 2 * 24 * 60 * 60) * 1000)
        let vm = Remote.tree([Remote.chatTab(1, session: "vm-quiet", host: "install:vm", title: "Quiet"), old,
                              Remote.chatTab(3, session: "vm-pinned", host: "install:vm", title: "Pinned")])
        let chats = Self.chats { [SidebarPriorityMachine(name: "gpu-box", store: vm)] }
        #expect(chats.togglePin("vm-pinned"))
        let ids = chats.entries().map(\.id)
        #expect(ids.contains("vm-quiet"), "an idle chat first seen now is listed")
        #expect(!ids.contains("vm-read"), "an idle chat whose last notice is two days old has aged out")
        let later = chats.entries(now: Date().addingTimeInterval(25 * 60 * 60)).map(\.id)
        #expect(!later.contains("vm-quiet"), "an idle remote row leaves a day after it was first seen")
        #expect(later.contains("vm-pinned"), "a pinned one stays")
        let lanes = chats.lanes
        let next = try #require(AgentPriorityRanking().nextChange(lanes, marks: chats.marks.state, now: Date()))
        #expect(next.timeIntervalSinceNow > 23 * 60 * 60, "the view wakes when the idle row ages out")
    }

    @Test func aReadOrSnoozeMarkOnAnUntimedNoticeOutlivesTheAppsMemory() async throws {
        let suite = "priority-remote-rows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Notices posted before the app connected carry no time.
        let vm = Remote.tree([
            Remote.chatTab(1, session: "vm-done", host: "install:vm", title: "Bump", notice: (61, .info, unread: true)),
            Remote.chatTab(2, session: "vm-asks", host: "install:vm", title: "Fix", notice: (62, .warning, unread: true)),
        ])
        // A busy machine with many untimed notices: the app's first-seen times do not all stay in memory.
        let flood = Remote.tree((0..<4200).map {
            Remote.chatTab(UInt64(100 + $0), session: "flood-\($0)", host: "install:flood", title: "f", notice: (UInt64(1000 + $0), .info, unread: true))
        })
        let flooding = Flag()
        let machines = { @MainActor in
            [SidebarPriorityMachine(name: "gpu-box", store: vm)] + (flooding.on ? [SidebarPriorityMachine(name: "busy", store: flood)] : [])
        }
        let chats = Self.chats(machines, marks: AgentPriorityMarks(defaults: defaults))
        #expect(chats.markRead("vm-done"))
        #expect(chats.snooze("vm-asks"))
        let row = { (chats: AgentPriorityChats, id: String) in chats.entries().first { $0.id == id } }
        #expect(row(chats, "vm-done")?.state == .idle)
        #expect(row(chats, "vm-asks") == nil)

        flooding.on = true
        _ = chats.entries()
        flooding.on = false
        try await Task.sleep(for: .milliseconds(5))
        #expect(row(chats, "vm-done")?.state == .idle, "the read mark holds once the first-seen time is gone")
        #expect(row(chats, "vm-asks") == nil, "the snooze holds too")

        // A relaunch: the marks load from disk; nothing else is remembered.
        let relaunched = Self.chats(machines, marks: AgentPriorityMarks(defaults: defaults))
        #expect(row(relaunched, "vm-done")?.state == .idle, "the read mark holds after a relaunch")
        #expect(row(relaunched, "vm-asks") == nil, "the snooze holds after a relaunch")
    }

    @Test func aClosedRemoteTabDropsOffAndLosesItsMarks() async throws {
        let store = DaemonStore()
        try Self.connected(store)
        store.apply(snapshot: Self.tree([
            Remote.chatTab(1, session: "vm-done", host: "install:vm", title: "Bump", notice: (71, .info, unread: true)),
            Remote.chatTab(2, session: "vm-quiet", host: "install:vm", title: "Read"),
        ]))
        let chats = Self.chats { [SidebarPriorityMachine(name: "gpu-box", store: store)] }
        #expect(chats.togglePin("vm-done"))
        let running = Self.running(chats)
        defer { running.task.cancel() }
        try await until { running.feed.panel()?.entries.count == 2 }
        #expect(chats.marks.state.pinned == ["vm-done"], "a listed chat keeps its pin")

        store.apply(snapshot: Self.tree([Remote.chatTab(2, session: "vm-quiet", host: "install:vm", title: "Read")]))
        #expect(running.feed.panel()?.entries.map(\.id) == ["vm-quiet"], "the closed tab's row is gone")
        try await until { chats.marks.state.pinned.isEmpty }
        #expect(chats.marks.state.pinned.isEmpty, "a chat its live machine no longer shows loses its marks")
    }

    @Test func aMachineThatIsNotConnectedKeepsItsRowsAndMarks() async throws {
        let store = DaemonStore()
        try Self.connected(store)
        store.apply(snapshot: Self.tree([
            Remote.chatTab(1, session: "vm-done", host: "install:vm", title: "Bump", notice: (81, .info, unread: true)),
            Remote.chatTab(2, session: "vm-quiet", host: "install:vm", title: "Read"),
        ]))
        let chats = Self.chats { [SidebarPriorityMachine(name: "gpu-box", store: store)] }
        #expect(chats.togglePin("vm-done"))
        let running = Self.running(chats)
        defer { running.task.cancel() }
        try await until { running.feed.panel()?.entries.count == 2 }

        store.connectionState = .disconnected("network down")
        #expect(Set(running.feed.panel()?.entries.map(\.id) ?? []) == ["vm-done", "vm-quiet"], "its last tree's rows stay listed")
        #expect(!chats.complete)
        // The tree changes while the machine is down (a stale or partial one): no mark is dropped.
        store.apply(snapshot: Self.tree([Remote.chatTab(2, session: "vm-quiet", host: "install:vm", title: "Read")]))
        try await until { running.feed.panel()?.entries.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(chats.marks.state.pinned == ["vm-done"], "marks are not pruned while a machine is not live")
    }

    @Test func oneChangeBuildsTheChatsOnce() async throws {
        let store = DaemonStore()
        try Self.connected(store)
        store.apply(snapshot: Self.tree([Remote.chatTab(1, session: "vm-done", host: "install:vm", title: "Bump", notice: (91, .info, unread: true))]))
        let builds = Builds()
        let chats = Self.chats({ [SidebarPriorityMachine(name: "gpu-box", store: store)] }, builds: builds)
        let running = Self.running(chats)
        defer { running.task.cancel() }
        try await until { builds.count > 0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(builds.count == 1, "the first rows build the chats once, not again to schedule and prune")
        builds.count = 0
        chats.marks.togglePin("vm-done")
        try await until { builds.count > 0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(builds.count == 1, "a mark change builds them once")
    }

    @Test func openingARemoteRowRevealsTheTabOnTheMachineWhoseRowItIs() throws {
        let vm = Remote.tree([Remote.chatTab(1, session: "vm-only", host: "install:vm", title: "VM"),
                              Remote.chatTab(2, session: "both", host: "install:vm", title: "Both on VM")])
        let box = Remote.tree([Remote.chatTab(11, session: "box-only", host: "install:box", title: "Box"),
                               Remote.chatTab(12, session: "both", host: "install:box", title: "Both on box")])
        let tab = { (store: DaemonStore, session: String) in
            store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.agentSession?.session == session }?.id
        }
        let chats = Self.chats { [SidebarPriorityMachine(name: "gpu-box", store: vm), SidebarPriorityMachine(name: "big-blue", store: box)] }
        #expect(chats.remoteTab(showing: "box-only") == tab(box, "box-only"))
        #expect(chats.remoteTab(showing: "vm-only") == tab(vm, "vm-only"))
        #expect(chats.entries().first { $0.id == "both" }?.machine == "gpu-box")
        let onVM = try #require(tab(vm, "both")), onBox = try #require(tab(box, "both"))
        #expect(onVM != onBox, "each machine's tab is its own")
        #expect(chats.remoteTab(showing: "both") == onVM, "the row's machine, the one its tag names")
        let boxFirst = Self.chats { [SidebarPriorityMachine(name: "big-blue", store: box), SidebarPriorityMachine(name: "gpu-box", store: vm)] }
        #expect(boxFirst.entries().first { $0.id == "both" }?.machine == "big-blue")
        #expect(boxFirst.remoteTab(showing: "both") == onBox, "with the box listed first its row and its tab are the box's")
        #expect(chats.remoteTab(showing: "nowhere") == nil)
    }

    @Test func aMarkOnARemoteNoticeEndsWhenARestartedDaemonReusesItsIdForANewNotice() async throws {
        let suite = "priority-remote-reuse-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let posted = UInt64(Date().timeIntervalSince1970 * 1000) - 60_000
        let ask = { (at: UInt64) in
            var tab = Remote.chatTab(1, session: "vm-asks", host: "install:vm", title: "Fix", notice: (12, .warning, unread: true))
            tab.notification?.createdAtMs = at
            var done = Remote.chatTab(2, session: "vm-done", host: "install:vm", title: "Bump", notice: (13, .info, unread: true))
            done.notification?.createdAtMs = at
            return Self.tree([tab, done])
        }
        let store = DaemonStore()
        store.apply(snapshot: ask(posted))
        let machines = { @MainActor in [SidebarPriorityMachine(name: "gpu-box", store: store)] }
        let chats = Self.chats(machines, marks: AgentPriorityMarks(defaults: defaults))
        #expect(chats.snooze("vm-asks"))
        #expect(chats.markRead("vm-done"))
        let row = { (chats: AgentPriorityChats, id: String) in chats.entries().first { $0.id == id } }
        #expect(row(chats, "vm-asks") == nil)
        #expect(row(chats, "vm-done")?.state == .idle)

        // The same notices after a reload: the marks still hold.
        let reloaded = Self.chats(machines, marks: AgentPriorityMarks(defaults: defaults))
        #expect(row(reloaded, "vm-asks") == nil, "the same notice at the same time stays snoozed after a reload")
        #expect(row(reloaded, "vm-done")?.state == .idle, "and stays read")

        // The daemon restarts and renumbers its notices: new ones reuse ids 12 and 13 at a new time.
        store.apply(snapshot: ask(posted + 30_000))
        #expect(row(reloaded, "vm-asks")?.state == .needsYou, "a new question that reuses a snoozed notice's id shows")
        #expect(row(reloaded, "vm-done")?.state == .done, "a new result that reuses a read notice's id shows unread")
    }

    static func identity(generation: String) throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"priority-remote-rows","generation":"\#(generation)"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func aMarkOnAnUntimedNoticeEndsWhenANewDaemonBootReusesItsId() async throws {
        // Current daemons send no time on a tab's notice.
        let ask = { (level: NotificationLevel) in
            Self.tree([Remote.chatTab(1, session: "vm-asks", host: "install:vm", title: "Fix", notice: (12, level, unread: true)),
                       Remote.chatTab(2, session: "vm-done", host: "install:vm", title: "Bump", notice: (13, .info, unread: true))])
        }
        let store = DaemonStore()
        store.noteHandshake(try Self.identity(generation: "boot-1"))
        store.connectionState = .connected(try Self.identity(generation: "boot-1"))
        store.apply(snapshot: ask(.warning))
        let chats = Self.chats { [SidebarPriorityMachine(name: "gpu-box", store: store)] }
        #expect(chats.snooze("vm-asks"))
        #expect(chats.markRead("vm-done"))
        let row = { (id: String) in chats.entries().first { $0.id == id } }
        #expect(row("vm-asks") == nil)
        #expect(row("vm-done")?.state == .idle)

        // The same connection redraws the rows (a tree update, a disconnect that keeps its last
        // tree, a reconnect to the same daemon boot): the marks hold.
        store.apply(snapshot: ask(.warning))
        #expect(row("vm-asks") == nil, "the same boot's notice stays snoozed across a re-render")
        #expect(row("vm-done")?.state == .idle, "and stays read")
        store.connectionState = .disconnected("network down")
        #expect(row("vm-asks") == nil && row("vm-done")?.state == .idle, "a disconnect keeps the marks")
        store.noteHandshake(try Self.identity(generation: "boot-1"))
        store.connectionState = .connected(try Self.identity(generation: "boot-1"))
        #expect(row("vm-asks") == nil && row("vm-done")?.state == .idle, "a reconnect to the same boot keeps them")

        // The daemon restarts: its new boot renumbers notices, and new ones reuse ids 12 and 13.
        store.connectionState = .disconnected("restarting")
        store.noteHandshake(try Self.identity(generation: "boot-2"))
        store.connectionState = .connected(try Self.identity(generation: "boot-2"))
        store.apply(snapshot: ask(.warning))
        #expect(row("vm-asks")?.state == .needsYou, "a new untimed question that reuses a snoozed notice's id shows")
        #expect(row("vm-done")?.state == .done, "a new untimed result that reuses a read notice's id shows unread")
    }

    @Test func archivingARemoteRowDoesNothing() throws {
        let vm = Remote.tree([Remote.chatTab(1, session: "vm-done", host: "install:vm", title: "Bump", notice: (95, .info, unread: true))])
        let chats = Self.chats { [SidebarPriorityMachine(name: "gpu-box", store: vm)] }
        #expect(!chats.archive("vm-done"), "no acpmux here owns another machine's chat")
        #expect(chats.marks.state.archived.isEmpty)
        #expect(chats.entries().map(\.id) == ["vm-done"], "the row stays")
    }
}
