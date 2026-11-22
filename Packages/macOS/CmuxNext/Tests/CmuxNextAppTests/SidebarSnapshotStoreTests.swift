import CmuxNextDesign
@testable import CmuxNextApp
import CmuxNextSidebar
import Foundation
import Testing

/// The saved sidebars (`SidebarSnapshotStore`): a round trip keeps what a
/// window draws first, writes wait for the debounce (an injected clock, no
/// wall time) or a quit flush, and live-only detail is never saved.
@Suite struct SidebarSnapshotStoreTests {
    static func snapshot(_ titles: [String]) -> SidebarSnapshot {
        let rows = titles.enumerated().map { index, title in
            SidebarWorkspace(id: WorkspaceID("ws-\(index)"), title: title, status: "running tests", unread: .count(3),
                             activity: .busy(progress: nil))
        }
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return SidebarSnapshot(sections: [SidebarSection(kind: .machine(local), nodes: rows.map(SidebarNode.workspace))],
                               profiles: [], activeProfileID: nil)
    }

    @Test func aRoundTripKeepsRowsAndDropsLiveDetail() async throws {
        let file = SidebarSnapshotFirstTests.tempFile()
        let store = SidebarSnapshotStore(file: file)
        await store.record(Self.snapshot(["api", "web"]), window: "w1", sequence: 1)
        await store.flush()
        let read = try #require(file.read())
        let rows = try #require(read.snapshot(for: "w1", fallback: false)).sidebarSections.flatMap(\.workspaces)
        #expect(rows.map(\.title) == ["api", "web"])
        #expect(rows.allSatisfy { $0.rowState == .stale && $0.status == nil && $0.unread == .none && $0.activity == .idle })
        #expect(SidebarSnapshotStore(file: file).launchDocument == read)
    }

    @Test func writesWaitForTheDebounce() async throws {
        let clock = ManualClock()
        let file = SidebarSnapshotFirstTests.tempFile()
        let store = SidebarSnapshotStore(file: file, clock: clock, debounce: .milliseconds(500))
        await store.record(Self.snapshot(["a"]), window: "w1", sequence: 1)
        await store.record(Self.snapshot(["a", "b"]), window: "w1", sequence: 2)
        await clock.sleepers(atLeast: 1)
        #expect(file.read() == nil)
        clock.advance(by: .milliseconds(500))
        for _ in 0..<2_000 {
            if await store.writeCount > 0 { break }
            await Task.yield()
        }
        #expect(await store.writeCount == 1)
        #expect(file.read()?.snapshot(for: "w1", fallback: false)?.workspaceIDs == ["ws-0", "ws-1"])
    }

    @Test func aLateRecordNeverRollsAWindowBack() async {
        let store = SidebarSnapshotStore(file: nil)
        await store.record(Self.snapshot(["new"]), window: "w1", sequence: 5)
        await store.record(Self.snapshot(["old"]), window: "w1", sequence: 4)
        #expect(await store.document.snapshot(for: "w1", fallback: false)?.sections.first?.nodes.first?.workspace?.title == "new")
    }

    @Test func theLaunchWindowFallsBackToTheMostRecentlyUsedWindow() {
        var document = SidebarSnapshotDocument()
        document.record(Self.snapshot(["one"]), window: "w1")
        document.record(Self.snapshot(["two"]), window: "w2")
        document.touch(window: "w1")
        #expect(document.snapshot(for: "fresh", fallback: true)?.workspaceIDs == ["ws-0"])
        #expect(document.snapshot(for: "fresh", fallback: false) == nil)
        document.forget(window: "w1")
        #expect(document.snapshot(for: "fresh", fallback: true)?.sections.first?.nodes.first?.workspace?.title == "two")
    }

    @Test func aCorruptOrNewerFileReadsAsNothing() throws {
        let file = SidebarSnapshotFirstTests.tempFile()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file.url)
        #expect(file.read() == nil)
        try Data(#"{"schemaVersion":99,"windows":[]}"#.utf8).write(to: file.url)
        #expect(file.read() == nil)
    }

    @Test func iconsSurviveTheRoundTrip() throws {
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let icons: [WorkspaceIcon] = [.symbol("terminal", tint: .green), .swatch(.red), .emoji("🚀")]
        let rows = icons.enumerated().map { SidebarWorkspace(id: WorkspaceID("w\($0)"), title: "t\($0)", icon: $1) }
        let snapshot = SidebarSnapshot(sections: [SidebarSection(kind: .machine(local), nodes: rows.map(SidebarNode.workspace))],
                                       profiles: [], activeProfileID: nil)
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.sidebarSections.flatMap(\.workspaces).map(\.icon) == icons)
    }
}
