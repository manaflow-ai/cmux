// TabCardSnapshots is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

/// Every tab keeps the last picture the phone drew of it when the person leaves it (for the grid
/// or another tab) and when the app goes to the background, so a card whose content is not ready
/// on a later launch draws that picture rather than an empty preview. Leo, 2026-11-24: "there are
/// too many empty previews in the safari grid thing we ought to be able to simply capture them
/// before they get hibernated maybe".
@MainActor @Suite(.serialized) struct TabCardLeaveCaptureTests {
    /// A terminal whose card picture is a striped image (never a placeholder). Like a real page
    /// (`GhosttyTerminalTabContent`), a tab keeps the same picture until it draws again
    /// (`draw`): a capture with `onlyIfChanged` of a tab that drew nothing hands that picture back.
    @MainActor final class CapturingTerminal: TerminalTabContent {
        var captures: [(tab: String, fresh: Bool)] = []
        /// Page copies taken (a capture that was not skipped as unchanged).
        var copies = 0
        private var pictures: [String: UIImage] = [:]
        private var drewSinceCard: Set<String> = []
        func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView { AnyView(EmptyView()) }
        func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView { AnyView(EmptyView()) }
        /// The tab's page drew output since its card was taken.
        func draw(_ id: String) { drewSinceCard.insert(id) }
        func hostsCard(for tab: WorkspaceTab) -> Bool { true }
        func captureCard(for tab: WorkspaceTab, fresh: Bool, onlyIfChanged: Bool, keep: @escaping @MainActor (UIImage) -> Void) {
            captures.append((tab.id, fresh))
            let changed = pictures[tab.id] == nil || drewSinceCard.contains(tab.id)
            if fresh, !onlyIfChanged || changed {
                copies += 1
                drewSinceCard.remove(tab.id)
                pictures[tab.id] = TabCardSnapshotTests.picture(.systemTeal, width: 120, height: 240)
            }
            let picture = pictures[tab.id] ?? TabCardSnapshotTests.picture(.systemTeal, width: 120, height: 240)
            pictures[tab.id] = picture
            keep(picture)
        }
    }

    final class Chat: AgentSessionSource {
        let loadsHistory: Bool
        init(loadsHistory: Bool) { self.loadsHistory = loadsHistory }
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let macID = "mac-1"

    static func snapshots(_ directory: URL) -> TabCardSnapshots {
        let snapshots = TabCardSnapshots(store: TabSnapshotStore(directory: directory),
                                         memoryPressure: MemoryPressure(observesSystem: false))
        snapshots.accountID = { "user-1" }
        return snapshots
    }

    /// A workspace of `count` terminal tabs on "mac-1" (`term1`...), `term1` on screen.
    static func terminalSource(_ snapshots: TabCardSnapshots, count: Int = 2) -> (WorkspaceTabsSource, CapturingTerminal) {
        let store = AppStore.mock(tabMemory: .inMemory())
        let tabs = (1...count).map { WorkspaceTab(id: "term\($0)", kind: .terminal, title: "zsh") }
        store.workspaces.append(Workspace(id: "ws-leave", macID: macID, title: "Leave", directory: "~", tabs: tabs, lastActivityAt: Date()))
        let terminal = CapturingTerminal()
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-leave", terminal: terminal)
        source.snapshots = snapshots
        source.rasterizer.snapshots = snapshots
        source.activate("term1")
        return (source, terminal)
    }

    /// The same directory read by a new store: the next launch.
    static func relaunched(_ directory: URL, _ key: TabSnapshotKey) async throws -> TabCardSnapshots {
        let next = snapshots(directory)
        #expect(next.entry(key).image == nil, "a new launch starts with nothing in memory")
        next.warm([key])
        try await TabCardSnapshotTests.wait("the picture is read from disk") { next.loads >= 1 }
        return next
    }

    @Test func aTerminalTabLeftForTheGridHasASavedPicture() async throws {
        let directory = TabCardSnapshotTests.directory()
        let snapshots = Self.snapshots(directory)
        let (source, terminal) = Self.terminalSource(snapshots)
        let key = try #require(snapshots.key(macID: Self.macID, tabID: "term1"))
        #expect(snapshots.entry(key).image == nil)

        source.overviewWillAppear()

        #expect(terminal.captures.contains { $0.tab == "term1" && !$0.fresh },
                "the grid's opening keeps the page's last frame, never a capture in its zoom: \(terminal.captures)")
        // Kept at a card's width (`keepPicture`): shown once scaled off the main thread.
        try await TabCardSnapshotTests.wait("the card shows the picture once scaled") { snapshots.entry(key).image != nil }
        try await TabCardSnapshotTests.wait("the picture is written") { snapshots.saves >= 1 }
        #expect(snapshots.store.record(key) != nil)

        let next = try await Self.relaunched(directory, key)
        #expect(next.entry(key).image != nil, "after a relaunch the unhosted terminal's card has its picture")
    }

    @Test func aTerminalTabLeftForAnotherTabHasASavedPicture() async throws {
        let directory = TabCardSnapshotTests.directory()
        let snapshots = Self.snapshots(directory)
        let (source, terminal) = Self.terminalSource(snapshots)
        let key = try #require(snapshots.key(macID: Self.macID, tabID: "term1"))

        source.activate("term2")

        #expect(terminal.captures.contains { $0.tab == "term1" && $0.fresh }, "the tab left is captured as it was: \(terminal.captures)")
        #expect(!terminal.captures.contains { $0.tab == "term2" }, "the tab opened is not")
        try await TabCardSnapshotTests.wait("the picture is written") { snapshots.saves >= 1 }
        let next = try await Self.relaunched(directory, key)
        #expect(next.entry(key).image != nil)
    }

    @Test func goingToTheBackgroundSavesTheTabOnScreen() async throws {
        let directory = TabCardSnapshotTests.directory()
        let snapshots = Self.snapshots(directory)
        let (source, terminal) = Self.terminalSource(snapshots)
        let key = try #require(snapshots.key(macID: Self.macID, tabID: "term1"))

        source.sceneActiveChanged(false)

        #expect(terminal.captures.contains { $0.tab == "term1" && $0.fresh }, "the tab on screen: \(terminal.captures)")
        try await TabCardSnapshotTests.wait("the picture is written") { snapshots.store.record(key) != nil }
        source.sceneActiveChanged(true)
        let next = try await Self.relaunched(directory, key)
        #expect(next.entry(key).image != nil)
    }

    /// An agent tab's picture drawn this launch is kept when it is left; after a relaunch its
    /// chat awaits history and its card draws that picture (`.lastKnown`), not an empty page.
    /// The picture is set by hand: what is under test is its keeping, not the rendering.
    @Test func anAgentTabLeftHasASavedPictureItsCardShowsAfterARelaunch() async throws {
        let directory = TabCardSnapshotTests.directory()
        let snapshots = Self.snapshots(directory)
        let key = try #require(snapshots.key(macID: Self.macID, tabID: "agent"))
        let rasterizer = AgentCardRasterizer(memoryPressure: MemoryPressure(observesSystem: false))
        rasterizer.snapshots = snapshots

        let feed = AgentCardFeed(store: AgentChatStore(source: Chat(loadsHistory: false)))
        feed.snapshotKey = key
        let rasterKey = AgentCardRasterKey.current(feed, colorScheme: .dark, page: CGSize(width: 402, height: 874),
                                                   visibleHeight: 566, topInset: 70, bottomInset: 110, scale: 1)
        feed.raster = (rasterKey, TabCardSnapshotTests.picture(.systemIndigo, width: 120, height: 170))

        #expect(rasterizer.keepLastKnown(feed, rasterKey, drawNow: false), "the drawn picture is kept")
        #expect(snapshots.entry(key).image != nil)
        try await TabCardSnapshotTests.wait("the picture is written") { snapshots.saves >= 1 }

        let next = try await Self.relaunched(directory, key)
        let waiting = AgentCardFeed(store: AgentChatStore(source: Chat(loadsHistory: true)))
        #expect(waiting.awaitingHistory, "the relaunched chat awaits its history")
        let lastKnown = next.entry(key).image
        #expect(lastKnown != nil)
        #expect(AgentTabCard.face(awaitingHistory: waiting.awaitingHistory, mayShowPicture: false, drawable: true,
                                  hasLastKnown: lastKnown != nil) == .lastKnown)
    }

    /// A chat still awaiting its history has nothing of its own to draw: leaving it keeps
    /// nothing, so the picture from before stays.
    @Test func anAgentTabAwaitingHistoryKeepsItsOlderPicture() async throws {
        let snapshots = Self.snapshots(TabCardSnapshotTests.directory())
        let key = try #require(snapshots.key(macID: Self.macID, tabID: "agent"))
        let rasterizer = AgentCardRasterizer(memoryPressure: MemoryPressure(observesSystem: false))
        rasterizer.snapshots = snapshots
        let feed = AgentCardFeed(store: AgentChatStore(source: Chat(loadsHistory: true)))
        feed.snapshotKey = key
        let rasterKey = AgentCardRasterKey.current(feed, colorScheme: .dark, page: CGSize(width: 402, height: 874),
                                                   visibleHeight: 566, topInset: 70, bottomInset: 110, scale: 1)
        feed.raster = (rasterKey, TabCardSnapshotTests.picture(.systemRed, width: 120, height: 170))

        #expect(!rasterizer.keepLastKnown(feed, rasterKey, drawNow: true))
        #expect(snapshots.entry(key).image == nil)
    }

    /// Going to the background costs a bounded amount whatever the tab count: with N hosted
    /// terminals, at most `backgroundPictureCap` tabs are captured (the tab on screen first,
    /// then the most recently shown), and a second backgrounding with nothing drawn since copies
    /// no page and encodes no picture.
    @Test func backgroundingIsBoundedAndEncodesNothingUnchanged() async throws {
        let count = 12
        let cap = WorkspaceTabsSource.backgroundPictureCap
        #expect(cap < count)
        let snapshots = Self.snapshots(TabCardSnapshotTests.directory())
        let (source, terminal) = Self.terminalSource(snapshots, count: count)
        // Shown most recently last: term9, then term5, then term1 on screen.
        source.activate("term9")
        source.activate("term5")
        source.activate("term1")
        terminal.captures = []
        let before = snapshots.encodes

        source.sceneActiveChanged(false)

        let first = terminal.captures.map(\.tab)
        #expect(first.count == cap, "at most \(cap) of \(count) hosted terminals are captured: \(first)")
        #expect(Array(first.prefix(3)) == ["term1", "term5", "term9"],
                "the tab on screen first, then the most recently shown: \(first)")
        #expect(snapshots.encodes - before <= cap, "one encode per captured tab at most")
        source.sceneActiveChanged(true)

        // Nothing drew: the next backgrounding copies no page and encodes no picture.
        terminal.captures = []
        let copies = terminal.copies, encodes = snapshots.encodes, unchanged = snapshots.unchanged
        source.sceneActiveChanged(false)
        #expect(terminal.captures.count == cap)
        #expect(terminal.copies == copies, "no page is copied again")
        #expect(snapshots.encodes == encodes, "an unchanged picture is not encoded again")
        #expect(snapshots.unchanged - unchanged == cap)
        source.sceneActiveChanged(true)

        // The tab on screen drew: only it is copied and encoded.
        terminal.draw("term1")
        source.sceneActiveChanged(false)
        #expect(terminal.copies == copies + 1)
        #expect(snapshots.encodes == encodes + 1)
    }

    /// An agent tab left for another tab is drawn 500 ms later: by then it is read again by its
    /// id, so a tab closed meanwhile keeps nothing (its picture would outlive it on disk).
    @Test func anAgentTabClosedBeforeItsDelayedPictureKeepsNothing() async throws {
        let snapshots = Self.snapshots(TabCardSnapshotTests.directory())
        let store = AppStore.mock(tabMemory: .inMemory())
        let tabs = [WorkspaceTab(id: "agent1", kind: .agent, title: "Codex", harness: "codex"),
                    WorkspaceTab(id: "term1", kind: .terminal, title: "zsh")]
        store.workspaces.append(Workspace(id: "ws-agent-close", macID: Self.macID, title: "Close", directory: "~",
                                          tabs: tabs, lastActivityAt: Date()))
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-agent-close", terminal: CapturingTerminal())
        source.snapshots = snapshots
        source.rasterizer.snapshots = snapshots
        source.activate("agent1")
        source.activate("term1")

        // The agent tab closes on the Mac inside the 500 ms.
        let index = try #require(store.workspaces.firstIndex { $0.id == "ws-agent-close" })
        store.workspaces[index].tabs.removeAll { $0.id == "agent1" }

        try await TabCardSnapshotTests.wait("the delayed picture came due") { source.droppedAgentPictures == 1 }
        let key = try #require(snapshots.key(macID: Self.macID, tabID: "agent1"))
        #expect(snapshots.entry(key).image == nil, "a closed tab keeps no picture")
    }
}
#endif
