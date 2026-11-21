import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-10: "make it so when i mousedown on switching space, it instantly switches ... changing
/// spaces in sidebar also feels kinda slow". A space switch changed only the window's state
/// (`WindowManager.switchProfile`) and left the rest to observers: the content swap to one main-actor turn, the
/// sidebar's rows to a second, the list's draw to a third, and then the old rows slid out. Every entrypoint now
/// shows the space in the turn of its input: the sidebar lists the space's rows at rest and the content area
/// shows its workspace before the input's handler returns. Each test reads the window with no await and no run
/// loop turn after the input, in a window the app's `WindowManager` holds.
@MainActor @Suite(.serialized)
struct SpaceSwitchSameTurnTests {
    static func bench() async throws -> SpaceSwitchBench {
        let bench = try await SpaceSwitchBench(total: 20, registered: true)
        #expect(bench.state.profileID == bench.rooms[0])
        // Setup, not the behaviour under test: on a loaded host the new window's first rows and content can need
        // more turns than the bench's own settle (one run of five started here with neither shown).
        var start = bench.showsNow(bench.rooms[0]), turns = 0
        while !(start.sidebar && start.content), turns < 2000 {
            bench.drain()
            try await Task.sleep(for: .milliseconds(1))
            turns += 1
            start = bench.showsNow(bench.rooms[0])
        }
        if turns > 0 { print("SPACE-SWITCH-SAMETURN the start state needed \(turns) more turns: \(start)") }
        #expect(start.sidebar && start.content && start.atRest, "the window does not start on its first space after \(turns) turns: \(start)")
        return bench
    }

    static func expectShown(_ room: ProfileID, in bench: SpaceSwitchBench, after input: String) {
        let shown = bench.showsNow(room)
        #expect(bench.state.profileID == room, "\(input): the window's space is \(bench.state.profileID.rawValue)")
        #expect(shown.sidebar, "\(input): the sidebar does not list the space's rows in the input's turn")
        #expect(shown.content, "\(input): the content area shows \(bench.shownWorkspace ?? "nothing"), not a workspace of the space")
        #expect(shown.atRest, "\(input): a page of the old space is beside the list")
    }

    /// The one path every entrypoint ends in (the keys, the palette, the CLI and the socket through the
    /// `space.*` actions, the sidebar's intent).
    @Test func aSwitchShowsTheSpaceAndItsWorkspaceInItsOwnTurn() async throws {
        let bench = try await Self.bench()
        defer { bench.close() }
        bench.services.windows.switchProfile(bench.rooms[1], in: bench.state)
        Self.expectShown(bench.rooms[1], in: bench, after: "switchProfile")
        bench.services.windows.switchProfile(bench.rooms[0], in: bench.state)
        Self.expectShown(bench.rooms[0], in: bench, after: "switchProfile back")
    }

    /// The real space bar in the real window: the press shows the space, before any release.
    @Test func aPressOnASpaceInTheBarShowsItBeforeTheRelease() async throws {
        let bench = try await Self.bench()
        defer { bench.close() }
        let window = try #require(bench.controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let bar = bench.controller.sidebar.container.sidebarView.profileBar
        try #require(bar.model.profiles.count == 2, "the bar shows \(bar.model.profiles.count) spaces")
        let slot = bar.slotRects()[1]
        try #require(bar.interactionIndex(at: NSPoint(x: slot.midX, y: slot.midY)) == 1, "the second space's dot is not under \(slot)")
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: bar.convert(NSPoint(x: slot.midX, y: slot.midY), to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        bar.mouseDown(with: event(.leftMouseDown))
        Self.expectShown(bench.rooms[1], in: bench, after: "mouse-down on the space's dot")
        bar.mouseUp(with: event(.leftMouseUp))
        Self.expectShown(bench.rooms[1], in: bench, after: "the release")
    }

    /// The keys and the palette (Next Space, Previous Space), the CLI and the socket (`space switch`).
    @Test func theSpaceActionsShowTheSpaceInTheirOwnTurn() async throws {
        let bench = try await Self.bench()
        defer { bench.close() }
        AppActions.bind(bench.services)
        let registry = bench.services.registry
        try #require(registry.perform("space.next"), "space.next did not run in this window")
        Self.expectShown(bench.rooms[1], in: bench, after: "space.next")
        try #require(registry.perform("space.previous"), "space.previous did not run in this window")
        Self.expectShown(bench.rooms[0], in: bench, after: "space.previous")
        let target = ActionInvocation(arguments: ["index": .int(2)])
        try #require(registry.perform("space.selectByNumber", invocation: target), "space.selectByNumber did not run in this window")
        Self.expectShown(bench.rooms[1], in: bench, after: "space.selectByNumber 2")
    }

    /// A workspace of another space picked by id (the palette, a notification, `workspace select`) shows its
    /// space's rows with it, not the old space's rows beside the new content: the first time (its content is
    /// built) and again once the window keeps it mounted.
    @Test func showingAWorkspaceOfAnotherSpaceShowsThatSpacesRowsWithIt() async throws {
        let bench = try await Self.bench()
        defer { bench.close() }
        let other = try #require(bench.keysByRoom[bench.rooms[1]]?.last)
        bench.services.windows.show(workspaceID: other, in: bench.state)
        Self.expectShown(bench.rooms[1], in: bench, after: "the first show(workspaceID:)")
        #expect(bench.shownWorkspace == other)
        bench.services.windows.switchProfile(bench.rooms[0], in: bench.state)
        Self.expectShown(bench.rooms[0], in: bench, after: "switchProfile back")
        bench.services.windows.show(workspaceID: other, in: bench.state)
        Self.expectShown(bench.rooms[1], in: bench, after: "show(workspaceID:) of a mounted workspace")
        #expect(bench.shownWorkspace == other)
    }
}
