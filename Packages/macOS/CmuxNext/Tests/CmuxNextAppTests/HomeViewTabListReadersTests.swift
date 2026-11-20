import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextKeepAwake
@testable import CmuxNextSettings
import Foundation
import Testing

/// A NEW TAB AND THE HOME VIEW's WATCH OF THE PERSON's AGENTS.
///
/// A home view of a Chief conversation with no message yet shows the person's agents (the first-run glance). Its
/// watch (`HomeHostView`, `agentsWatch`) read the tab list of each pane of each workspace in ONE observation, shown
/// or not. One new tab in one pane then cancelled each registration of that observation, and the next turn read the
/// whole session again: the cost of one New Tab key grew with the session (`CmdTTabListReadersTests` holds the same
/// rule for three app-lifetime services). Now the watch has a feed with one observation for each workspace
/// (`HomeAgentGlances.feed(while:)`), and the view's stream reads the feed's one cell.
///
/// The count (`ObservationWakes`, no clock): a new terminal tab in each of a few workspaces, one at a time, by the
/// store's intent as the key does it. A terminal with no agent changes no glance, so it must wake no observation
/// made in the home view's file, and an observation of one workspace's agents wakes for its own workspace only. The
/// rows print each observation that a new tab woke, by the place where it was made, for a session of 2 and of 60
/// workspaces side by side: a place whose count grows with the session is seen at once.
///
/// The feed moves its cell in a task of its own, after the write: the count of the write does not have the wake of
/// the view's stream. So the view is made under a counter of its own. Each task that the view makes, and each task
/// made in one of them (the feed's, each workspace's), counts there: a move of the cell is one wake of the view's
/// stream in that counter. The rows take the wakes of each place of the view's own file there, with no line number:
/// row 1 wants that their sum does not grow at a new tab, row 2 that it grows at an agent's report.
///
/// Limits: the count has the streams, trackings and loops that record themselves in `ObservationWakes`; a SwiftUI
/// body is not in it. The rows do not count what the New Tab places feed does for each open New Tab page (it is no
/// observation wake). The home view is in no window in rows 1 and 3.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct HomeViewTabListReadersTests {
    private static let conversation = "conv_local"
    private static func key(_ workspace: Int) -> String { "home-readers-ws-\(workspace)" }
    /// The start of the key of each place in the view's own file, where the view makes its streams (the one of
    /// the agents is `agentsWatch`). The rows take the wakes of ALL the places of that file: no line number is here.
    private static let viewFile = "CmuxNextApp/HomeHostView.swift:"
    /// The keep-awake services this suite started (the app has one, for its lifetime).
    private static var kept: [KeepAwakeService] = []

    /// The Chief conversation of the scene's home view.
    private enum Chief: String {
        /// No message yet: the home view shows the person's agents.
        case empty = "a Chief with no message"
        /// One message: the home view shows the conversation, and its watch reads no tab.
        case oneMessage = "a Chief with 1 message"
    }

    private enum Change {
        /// One new terminal tab in the first pane of each changed workspace.
        case newTerminalTab
        /// The first terminal of the first workspace gets an agent's report.
        case firstTerminalGetsAnAgent
    }

    /// What one place (`#fileID:#line`) of observations did in a run.
    private struct Place {
        /// The observation instances made at the place that woke.
        var instances = 0
        /// The wakes of all of them.
        var wakes = 0
        /// The most changed workspaces that woke ONE instance.
        var most = 0
    }

    private struct Run {
        var places: [String: Place] = [:]
        var changed = 0
        var glancesBefore = 0
        var glancesAfter = 0
        /// The tab ids of the agents that the home view's first-run panel lists, before and after the changes.
        var shownBefore: [String] = []
        var shownAfter: [String] = []
        /// The tab that got an agent (`firstTerminalGetsAnAgent`).
        var agentTab = ""
        /// The tab that had an agent before the view was made (`agentBefore`).
        var agentBefore = ""
        /// The wakes of each place of the view's own file in the view's own counter, after the view's first turns
        /// and after the changes. The rows read their sum.
        var streamsBefore: [String: Int] = [:]
        var streamsAfter: [String: Int] = [:]
        var lastSeq: UInt64 = 0
    }

    /// The wakes of each place of the view's own file in `wakes`.
    private static func viewStreams(_ wakes: ObservationWakes) -> [String: Int] {
        wakes.bySite.filter { $0.key.hasPrefix(viewFile) }
    }

    private static func sum(_ places: [String: Int]) -> Int { places.values.reduce(0, +) }

    /// Each place with its count, in the order of the keys.
    private static func text(_ places: [String: Int]) -> String {
        "[" + places.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "]"
    }

    /// `workspaces` workspaces, each one screen with one pane of two terminals and one WebKit page.
    private static func tree(workspaces: Int) -> DaemonTree {
        let snapshots = (1...workspaces).map { workspace in
            let first = UInt64((workspace - 1) * 3)
            let tabs = [
                TabSnapshot(surface: SurfaceID(rawValue: first + 1), title: "zsh"),
                TabSnapshot(surface: SurfaceID(rawValue: first + 2), title: "zsh"),
                TabSnapshot(surface: SurfaceID(rawValue: first + 3), kind: .browser, url: "http://127.0.0.1:9/\(workspace)",
                            browserRenderer: "frontend", browserEngine: "webkit"),
            ]
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(workspace)), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(workspace)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(workspace)), key: WorkspaceKey(rawValue: key(workspace)),
                                     name: "workspace \(workspace)", screens: [screen])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: snapshots)
        tree.personal = PersonalState(workspaces: (1...workspaces).map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key($0)), index: $0 - 1)
        })
        return tree
    }

    /// How many agents the session has for the home view's glance, read with no observation.
    private static func glanceCount(_ services: AppServices) -> Int {
        services.machines.allWorkspaces.reduce(0) { $0 + HomeAgentGlances(services: services).glances(in: $1.0).count }
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<80 { await Task.yield() }
    }

    /// The app as `CmdTTabListReadersTests` makes it (a whole window of a session of `workspaces` workspaces, the
    /// last one shows, with the two services the app delegate starts), and a home view of `chief`'s conversation.
    /// Then `change`, each write under its own counter. `agentBefore`: the first terminal of the last workspace
    /// has an agent before the view is made.
    private static func run(workspaces: Int, chief: Chief, change: Change, viewInAWindow: Bool = false,
                            agentBefore: Bool = false) async throws -> Run {
        _ = NSApplication.shared
        // No Home caches folder is set, so the Home service keeps its caches in a temporary folder of its own:
        // the Home store's durable copy is this run's, never a real Chief's.
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(workspaces: workspaces))
        try #require(store.workspaces.count == workspaces, "fixture: \(store.workspaces.count) workspaces, not \(workspaces)")

        let clipboardReads = TerminalClipboardReadService(services: services)
        clipboardReads.start()
        defer { clipboardReads.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "home-view-readers-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let keepAwake = KeepAwakeService()
        kept.append(keepAwake) // its power-source monitor has an unretained context: never freed in this process
        keepAwake.start(settings: settings, store: store)

        // The Home store lists ONE Chief conversation, as this Mac's owner reports it.
        let id = CmuxHomeCore.ConversationID(conversation)
        let me = services.home.homeSource.me
        let date = Date(timeIntervalSince1970: 1_000)
        let agent = CmuxHomeCore.Participant(id: CmuxHomeCore.ParticipantID("agent_mux"), kind: .agent, displayName: "Chief", agentClass: .chief)
        let summary = CmuxHomeCore.ConversationSummary(id: id, owner: .local, title: "Chief", participants: [me, agent],
                                                       lastSeq: chief == .empty ? 0 : 1, createdAt: date, updatedAt: date)
        services.home.homeSource.publish(.inbox(CmuxHomeCore.InboxSnapshot(me: me, conversations: [summary], rev: 1)))
        let home = services.home.homeStore
        home.start()
        for _ in 0..<400 where home.rows.first(where: { $0.summary.id == id }) == nil { await drainMain() }
        let listed = try #require(home.rows.first(where: { $0.summary.id == id })?.summary, "fixture: the Home store does not list the Chief conversation")
        try #require(listed.participants.contains { $0.agentClass == .chief }, "fixture: the conversation has no Chief")
        try #require(listed.lastSeq == (chief == .empty ? 0 : 1), "fixture: the conversation's last sequence is \(listed.lastSeq)")

        let keys = [key(workspaces)] + (1..<workspaces).map(key)
        let controller = try #require(services.windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1600, height: 900)))
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent == nil { await drainMain() }
        try #require(controller.workspaceContent).contentView.layoutSubtreeIfNeeded()

        // The home view, as the app makes it for a Chief conversation. In no window, or the content of a window of
        // its own that is not on a screen. It is made under a counter of its own (the suite's head comment).
        var agentBeforeTab = ""
        if agentBefore {
            let tab = try #require(store.workspaces.first { $0.key?.rawValue == key(workspaces) }?.screens.first?.panes.first?.tabs.first,
                                   "fixture: the last workspace has no tab")
            tab.setAgent(AgentStatus(surface: tab.surface, state: .working, source: "hook", agent: "codex", updatedAtMs: 1_000))
            try #require(tab.agent != nil, "fixture: the tab of the last workspace got no agent")
            agentBeforeTab = tab.id
        }
        let viewWakes = ObservationWakes()
        var made: HomeHostView?
        ObservationWakes.$current.withValue(viewWakes) {
            made = HomeHostView(services: services, conversation: conversation)
        }
        let view = try #require(made, "fixture: no home view")
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        var viewWindow: NSWindow?
        if viewInAWindow {
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            viewWindow = window
        }
        defer { viewWindow?.close() }
        view.layoutSubtreeIfNeeded()
        for _ in 0..<4 { await drainMain() } // every observer armed its first tracking

        var run = Run()
        run.lastSeq = listed.lastSeq
        run.glancesBefore = glanceCount(services)
        run.shownBefore = view.transcript.firstRun.agents.map(\.id)
        run.agentBefore = agentBeforeTab
        run.streamsBefore = viewStreams(viewWakes)
        var woken: [ObjectIdentifier: (place: String, workspaces: Int)] = [:]
        var wakesByPlace: [String: Int] = [:]
        // At most four workspaces, spread over the session; two are enough to see a reader of more than one.
        let numbers = change == .newTerminalTab ? Array(Set([1, 2, max(1, workspaces / 2), workspaces])).sorted() : [1]
        for number in numbers {
            let workspace = try #require(store.workspaces.first { $0.key?.rawValue == key(number) }, "fixture: no workspace \(number)")
            let pane = try #require(workspace.screens.first?.panes.first, "fixture: workspace \(number) has no pane")
            let wakes = ObservationWakes()
            switch change {
            case .newTerminalTab:
                let before = pane.tabs.count
                ObservationWakes.$current.withValue(wakes) {
                    store.intend(.createTab(pane: pane.handle, provisional: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)),
                                 transaction: ClientTransactionID.generate())
                }
                try #require(pane.tabs.count == before + 1, "fixture: the intent made \(pane.tabs.count - before) tabs in workspace \(number), not 1")
            case .firstTerminalGetsAnAgent:
                let tab = try #require(pane.tabs.first, "fixture: workspace \(number) has no tab")
                try #require(tab.agent == nil, "fixture: the tab has an agent already")
                ObservationWakes.$current.withValue(wakes) {
                    tab.setAgent(AgentStatus(surface: tab.surface, state: .working, source: "hook", agent: "codex", updatedAtMs: 1_000))
                }
                try #require(tab.agent != nil, "fixture: the tab got no agent")
                run.agentTab = tab.id
                // The view lists the agent some turns after the write: a fixed number of yields, no wait for time.
                for _ in 0..<20 where !view.transcript.firstRun.agents.contains(where: { $0.id == tab.id }) { await drainMain() }
            }
            // The woken observers re-arm before the next workspace changes. A raw tracking counts its wake in the hop
            // its `onChange` queued (the hop has this scope's counter), so the count is read after the hops ran.
            await drainMain()
            for (instance, place) in wakes.woken { woken[instance, default: (place, 0)].workspaces += 1 }
            for (place, count) in wakes.bySite { wakesByPlace[place, default: 0] += count }
        }
        run.changed = numbers.count
        run.glancesAfter = glanceCount(services)
        run.shownAfter = view.transcript.firstRun.agents.map(\.id)
        run.streamsAfter = viewStreams(viewWakes)
        for observer in woken.values {
            var place = run.places[observer.place] ?? Place()
            place.instances += 1
            place.most = max(place.most, observer.workspaces)
            run.places[observer.place] = place
        }
        for (name, count) in wakesByPlace { run.places[name, default: Place()].wakes = count }
        _ = view // the view lives to here
        return run
    }

    /// One line for each place that woke in one of the two runs, the small session beside the large one.
    private static func printPlaces(_ row: String, small: Run, large: Run, sizes: (Int, Int)) {
        func text(_ place: Place?) -> String {
            guard let place else { return "none" }
            return "\(place.instances) instances, \(place.wakes) wakes, one woke for \(place.most) workspaces"
        }
        print("HomeViewTabListReadersTests: \(row): \(sizes.0) workspaces, \(small.changed) changed, \(small.places.count) places woke | "
            + "\(sizes.1) workspaces, \(large.changed) changed, \(large.places.count) places woke | the agents' glances \(large.glancesBefore) -> \(large.glancesAfter)")
        for name in Set(small.places.keys).union(large.places.keys).sorted() {
            print("HomeViewTabListReadersTests: \(row): place \(name): \(sizes.0) workspaces: \(text(small.places[name])) | \(sizes.1) workspaces: \(text(large.places[name]))")
        }
    }

    private static func homeView(_ run: Run) -> [String] {
        run.places.filter { $0.key.contains("HomeHostView.swift") }.map { "\($0.key): \($0.value.wakes) wakes, \($0.value.most) workspaces" }.sorted()
    }

    /// Row 1. The home view of a Chief with no message is in no window. A new terminal tab changes no glance of the
    /// person's agents, so it wakes no observation of the home view, in a small session and in a large one.
    @Test func aNewTerminalTabWakesNoObservationOfAHomeViewOfAnEmptyChief() async throws {
        let small = try await Self.run(workspaces: 2, chief: .empty, change: .newTerminalTab)
        let large = try await Self.run(workspaces: 60, chief: .empty, change: .newTerminalTab)
        Self.printPlaces("row 1, a new terminal tab, \(Chief.empty.rawValue), the home view in no window", small: small, large: large, sizes: (2, 60))
        try #require(large.changed == 4, "fixture: \(large.changed) changed workspaces, not 4")
        #expect(small.glancesBefore == small.glancesAfter && large.glancesBefore == large.glancesAfter, "fixture: a terminal with no agent changed the glances")
        #expect(Self.homeView(small).isEmpty, "with 2 workspaces a new terminal tab woke the home view: \(Self.homeView(small))")
        #expect(Self.homeView(large).isEmpty, "with 60 workspaces a new terminal tab woke the home view: \(Self.homeView(large))")
        // The view's agents have one observation for each workspace (made in `HomeAgentGlances.swift`): a new tab
        // wakes the one of its own workspace, and no observation wakes for the tab of a second workspace.
        for (size, session) in [(2, small), (60, large)] {
            let wide = session.places.filter { $0.key.contains("HomeAgentGlances.swift") && ($0.value.most > 1 || $0.value.instances > session.changed) }
            #expect(wide.isEmpty, "with \(size) workspaces an observation of the agents woke for more than its own workspace: \(wide.keys.sorted())")
            // The feed is armed: one observation of the agents woke for each changed workspace, not fewer.
            let armed = session.places.filter { $0.key.contains("HomeAgentGlances.swift") }.values.reduce(0) { $0 + $1.instances }
            #expect(armed == session.changed, "with \(size) workspaces \(armed) observations of the agents woke for \(session.changed) changed workspaces")
            // The streams of the view's own file, in the view's own counter: no new tab ran one of them.
            let (before, after) = (Self.sum(session.streamsBefore), Self.sum(session.streamsAfter))
            let places = "\(Self.text(session.streamsBefore)) -> \(Self.text(session.streamsAfter))"
            print("HomeViewTabListReadersTests: row 1: \(size) workspaces: the wakes of the streams of the view's file \(before) -> \(after); each place: \(places)")
            // One literal: an expectation's comment is not a sum of two strings.
            #expect(after == before, "with \(size) workspaces the new tabs woke a stream of the view's file: \(before) -> \(after) wakes, \(places)")
        }
    }

    /// Row 2, what must stay: a terminal that gets an agent's report is one more glance of the person's agents, and
    /// the home view of a Chief with no message lists it (the first-run panel's agents). The view is the content of
    /// a window. This row also proves that the watch of rows 1 and 3 is armed in this scene. The second workspace
    /// has an agent before the view is made: the view lists it from its first turns (the feed's first items), then
    /// both, in the order of the workspaces. The report is one wake of the view's stream in the view's own counter:
    /// so row 1's count can see that stream.
    @Test func aTerminalThatGetsAnAgentWakesTheHomeViewOfAnEmptyChief() async throws {
        let run = try await Self.run(workspaces: 2, chief: .empty, change: .firstTerminalGetsAnAgent, viewInAWindow: true, agentBefore: true)
        Self.printPlaces("row 2, a terminal gets an agent, \(Chief.empty.rawValue), the home view in a window", small: run, large: run, sizes: (2, 2))
        #expect(run.glancesAfter == run.glancesBefore + 1, "the agents' glances went from \(run.glancesBefore) to \(run.glancesAfter)")
        let (before, after) = (Self.sum(run.streamsBefore), Self.sum(run.streamsAfter))
        print("HomeViewTabListReadersTests: row 2: the home view lists the agents \(run.shownBefore) -> \(run.shownAfter); the tab with the agent = \(run.agentTab); "
            + "the tab with an agent before the view = \(run.agentBefore); the wakes of the streams of the view's file \(before) -> \(after); "
            + "each place: \(Self.text(run.streamsBefore)) -> \(Self.text(run.streamsAfter))")
        #expect(run.shownBefore == [run.agentBefore], "the home view lists the agents \(run.shownBefore) at its start, want [\(run.agentBefore)]")
        #expect(run.shownAfter == [run.agentTab, run.agentBefore],
                "the home view lists the agents \(run.shownAfter) after the report, want [\(run.agentTab), \(run.agentBefore)]")
        #expect(after > before, "the report woke no stream of the view's file: \(before) -> \(after) wakes")
    }

    /// Row 3, a control that only prints: the same new terminal tabs with a home view whose Chief has one message
    /// (the watch reads no tab then). Each place that a new tab woke, for 2 and for 60 workspaces.
    @Test func aNewTerminalTabWithAHomeViewOfAChiefWithAMessagePrintsEachWokenPlace() async throws {
        let small = try await Self.run(workspaces: 2, chief: .oneMessage, change: .newTerminalTab)
        let large = try await Self.run(workspaces: 60, chief: .oneMessage, change: .newTerminalTab)
        Self.printPlaces("row 3, a new terminal tab, \(Chief.oneMessage.rawValue), the home view in no window", small: small, large: large, sizes: (2, 60))
        try #require(large.changed == 4, "fixture: \(large.changed) changed workspaces, not 4")
    }
}
