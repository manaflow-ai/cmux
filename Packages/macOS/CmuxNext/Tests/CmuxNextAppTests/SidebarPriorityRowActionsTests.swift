import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextPalette
import CmuxNextSidebar
import Foundation
import Testing

/// A Priority row's mark read, pin, snooze and archive are registered actions (cmux-shared-behavior:
/// one action path for every entrypoint). The hover buttons, the row's right-click menu and the
/// palette run them through the registry on the row's chat (`agent-chat:<session id>`), and each
/// writes the same mark the hover button wrote before it was an action; the archive is Archive Chat.
@MainActor
struct SidebarPriorityRowActionsTests {
    enum Row: String, CaseIterable, Sendable {
        case markRead, togglePin, snooze, archive

        func button(_ chat: String) -> SidebarPriorityAction {
            switch self {
            case .markRead: .markRead(chat)
            case .togglePin: .togglePin(chat)
            case .snooze: .snooze(chat)
            case .archive: .archive(chat)
            }
        }

        var actionID: ActionID {
            switch self {
            case .markRead: "sidebar.priority.markRead"
            case .togglePin: "sidebar.priority.togglePin"
            case .snooze: "sidebar.priority.snooze"
            case .archive: "agentPane.archiveChat"
            }
        }

        /// The mark the hover button wrote straight into `AgentPriorityMarks` before it was an action.
        @MainActor func writeMark(_ lane: AgentActivityLane, into marks: AgentPriorityMarks) {
            switch self {
            case .markRead: marks.markRead(lane)
            case .togglePin: marks.togglePin(lane.id)
            case .snooze: marks.snooze(lane)
            case .archive: marks.archive(lane.id)
            }
        }
    }

    static let socket = "/tmp/pv-acpmux.sock"
    /// One turn end for every fixture, so two fixtures' marks compare equal.
    static let since = Date().addingTimeInterval(-20 * 60)

    /// Two chats on one acpmux: a finished result nobody saw, and a question waiting on the person.
    @MainActor final class Fixture {
        let store = AgentLaneStore()
        let chats: AgentPriorityChats
        let registry = ActionRegistry.standard()
        let requests: AsyncStream<String>

        /// `refuseArchive`: acpmux answers every archive with an error, as for a peer's chat it does not own.
        init(bind: Bool = true, refuseArchive: Bool = false) {
            store.socketPath = SidebarPriorityRowActionsTests.socket
            store.live = true
            let since = SidebarPriorityRowActionsTests.since
            for (id, state, unread) in [("done", AgentActivityLane.State.idle, true), ("asks", .input, false)] {
                store.lanes[id] = AgentActivityLane(id: id, name: id, title: "Chat \(id)", peer: nil, parent: nil, state: state,
                                                    since: since, error: nil, unread: unread, project: "cmux")
            }
            let (requests, sink) = AsyncStream.makeStream(of: String.self)
            self.requests = requests
            chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store]) { socket, id in
                sink.yield("\(socket) \(id)")
                if refuseArchive { throw ArchiveRefused() }
            }
            guard bind else { return }
            let actions = SidebarPriorityRowActions(chats: chats)
            actions.bind(into: registry)
            actions.bindArchive(into: registry) { _ in Issue.record("a Priority row's archive ran the focused chat's") }
        }

        var marks: AgentPriorityMarks.State { chats.marks.state }
    }

    /// Snooze ends an hour after the press: compare the marks with the end dropped, then the end.
    static func sameMarks(_ actual: AgentPriorityMarks.State, _ expected: AgentPriorityMarks.State) -> Bool {
        func dropEnds(_ state: AgentPriorityMarks.State) -> AgentPriorityMarks.State {
            var state = state
            state.snoozed = state.snoozed.mapValues { .init(stamp: $0.stamp, until: .distantPast) }
            return state
        }
        let ends = zip(actual.snoozed.values.map(\.until), expected.snoozed.values.map(\.until))
        return dropEnds(actual) == dropEnds(expected) && ends.allSatisfy { abs($0.timeIntervalSince($1)) < 60 }
    }

    @Test(arguments: Row.allCases)
    func aRowActionRunThroughTheRegistryWritesTheMarkTheButtonWrote(row: Row) async throws {
        let fixture = Fixture()
        let lane = try #require(fixture.store.lanes["done"])
        let expected = AgentPriorityMarks(defaults: nil)
        row.writeMark(lane, into: expected)
        #expect(fixture.marks != expected.state, "the fixture starts without the mark")

        let ran = fixture.registry.perform(row.actionID, invocation: ActionInvocation(target: ActionTargetRef(kind: .agentChat, id: "done")))

        #expect(ran)
        #expect(Self.sameMarks(fixture.marks, expected.state), "\(row): \(fixture.marks) != \(expected.state)")
        if row == .archive {
            // Hidden at once, then archived in the acpmux that lists the chat.
            var requests = fixture.requests.makeAsyncIterator()
            #expect(await requests.next() == "\(Self.socket) done")
        }
    }

    /// The hover button sends its choice to the feed, which runs the registered action: with the
    /// action unbound nothing changes, bound it writes what a registry run writes.
    @Test(arguments: Row.allCases)
    func aHoverButtonRunsTheRegisteredAction(row: Row) throws {
        let unbound = Fixture(bind: false)
        feed(unbound).perform(row.button("done"))
        #expect(unbound.marks == AgentPriorityMarks.State(), "\(row): the button wrote a mark without the action")

        let viaButton = Fixture(), viaRegistry = Fixture()
        feed(viaButton).perform(row.button("done"))
        viaRegistry.registry.perform(row.actionID, invocation: ActionInvocation(target: ActionTargetRef(kind: .agentChat, id: "done")))
        #expect(viaButton.marks != AgentPriorityMarks.State())
        #expect(Self.sameMarks(viaButton.marks, viaRegistry.marks), "\(row)")
    }

    @Test func aRowsMenuListsItsActionsAndEachRunsOnTheRowsChat() throws {
        let fixture = Fixture()
        let menu = fixture.registry.makeContextMenu(for: .priorityRow, target: SidebarPriorityRowActions.target("done"))
        let rows = Self.leafItems(menu).compactMap { item in ActionRegistry.menuRun(of: item).map { (item, $0) } }
        #expect(rows.map(\.1.id) == Row.allCases.map(\.actionID))
        #expect(rows.allSatisfy { $0.1.target == ActionTargetRef(kind: .agentChat, id: "done") })
        // The row names its chat, so its menu asks nothing: no row ends in "…" as the palette's do.
        #expect(rows.allSatisfy { !$0.0.title.hasSuffix("…") }, "\(rows.map(\.0.title))")
        let pin = try #require(rows.first { $0.1.id == Row.togglePin.actionID }?.0)
        #expect(pin.title == fixture.chats.entry("done")?.pinTitle)

        _ = (pin.target as? NSObject)?.perform(pin.action, with: pin)
        #expect(fixture.marks.pinned == ["done"])
        let unpin = Self.leafItems(fixture.registry.makeContextMenu(for: .priorityRow, target: SidebarPriorityRowActions.target("done")))
            .first { ActionRegistry.menuRun(of: $0)?.id == Row.togglePin.actionID }
        #expect(unpin?.title == fixture.chats.entry("done")?.pinTitle && fixture.chats.entry("done")?.pinned == true)

        // A question is answered, not read: its row has no Mark as Read, as its button is greyed.
        let question = Self.leafItems(fixture.registry.makeContextMenu(for: .priorityRow, target: SidebarPriorityRowActions.target("asks")))
        #expect(!question.contains { ActionRegistry.menuRun(of: $0)?.id == Row.markRead.actionID })
    }

    /// The palette offers each row action and asks which chat, from the Priority rows in rank order.
    @Test func thePaletteAsksWhichPriorityChat() throws {
        let fixture = Fixture()
        for row in Row.allCases where row != .archive {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == row.actionID })
            #expect(descriptor.surfaces.contains(.palette) && descriptor.surfacePlan.palette == .offered)
            #expect(descriptor.arguments.map(\.kind) == [.target(.agentChat)])
            #expect(descriptor.defaultShortcut == nil, "row actions take no default key")
        }
        let source = PriorityChatTargetSource(chats: fixture.chats, next: NoTargets())
        #expect(source.targets(of: .agentChat).map(\.id) == ["asks", "done"])
        #expect(source.title(of: ActionTargetRef(kind: .agentChat, id: "done")) == "Chat done")

        let picked = ActionInvocation(arguments: ["chat": .target(ActionTargetRef(kind: .agentChat, id: "done"))])
        fixture.registry.perform(Row.togglePin.actionID, invocation: picked)
        #expect(fixture.marks.pinned == ["done"])
    }

    /// With the Priority view off its rows' actions do not run, Archive Chat on a row's chat
    /// included, and each says why; Archive Chat on the focused chat (no row target) still runs.
    @Test func withThePriorityViewOffNoRowActionRunsButTheFocusedChatStillArchives() throws {
        let fixture = Fixture(bind: false)
        let reason = "The Priority view is off."
        let focused = Counter()
        let actions = SidebarPriorityRowActions(chats: fixture.chats, unavailable: { reason })
        actions.bind(into: fixture.registry)
        actions.bindArchive(into: fixture.registry) { _ in focused.count += 1 }
        for row in Row.allCases {
            let invocation = ActionInvocation(target: SidebarPriorityRowActions.target("done"))
            #expect(ActionTargetReasons.reason(for: row.actionID, invocation: invocation, in: fixture.registry) == reason, "\(row)")
            fixture.registry.perform(row.actionID, invocation: invocation)
        }
        #expect(fixture.marks == AgentPriorityMarks.State(), "a row action ran with the view off")
        // An agent chat has focus: Archive Chat with no target is that chat's.
        fixture.registry.context = [.agentPaneFocused]
        fixture.registry.perform(Row.archive.actionID, invocation: ActionInvocation())
        #expect(focused.count == 1, "the focused chat's Archive waits on the Priority view")
    }

    /// acpmux refusing an archive (a peer's chat it does not own, a dropped socket) shows the row
    /// again: the chat hides at once, then comes back when the refusal arrives.
    @Test func aRefusedArchiveShowsTheRowAgain() async throws {
        let fixture = Fixture(refuseArchive: true)
        #expect(fixture.chats.entry("done") != nil)
        #expect(fixture.registry.perform(Row.archive.actionID, invocation: ActionInvocation(target: SidebarPriorityRowActions.target("done"))))
        #expect(fixture.chats.entry("done") == nil, "the archived row stayed until acpmux answered")
        var requests = fixture.requests.makeAsyncIterator()
        #expect(await requests.next() == "\(Self.socket) done")
        let deadline = ContinuousClock.now + .seconds(2)
        while fixture.marks.archived.contains("done"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!fixture.marks.archived.contains("done"), "a refused archive kept the chat hidden here only")
        #expect(fixture.chats.entry("done") != nil, "the refused chat's row did not come back")
    }

    @Test func aChatNoAcpmuxListsChangesNothing() {
        let fixture = Fixture()
        for row in Row.allCases {
            fixture.registry.perform(row.actionID, invocation: ActionInvocation(target: ActionTargetRef(kind: .agentChat, id: "gone")))
        }
        #expect(fixture.marks == AgentPriorityMarks.State())
    }

    private func feed(_ fixture: Fixture) -> SidebarPriorityFeed {
        let registry = fixture.registry
        return SidebarPriorityFeed(
            settings: .init(enabled: { true }, shown: { true }),
            hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: { SidebarPriorityRowActions.perform($0, in: registry) }, toggleShown: {}),
            chats: fixture.chats
        )
    }

    private static func leafItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in item.submenu.map(leafItems) ?? (item.isSeparatorItem ? [] : [item]) }
    }
}

private struct ArchiveRefused: Error {}

@MainActor private final class Counter {
    var count = 0
}

@MainActor private final class NoTargets: PaletteTargetSource {
    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] { [] }
}
