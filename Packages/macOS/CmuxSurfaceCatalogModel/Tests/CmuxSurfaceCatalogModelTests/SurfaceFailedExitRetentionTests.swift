import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

/// Failed tabless runs used to stay in a machine's catalog forever: the daemon
/// keeps every exit receipt and only the tree aged them, so every snapshot
/// carried the whole history. Retention now bounds them where they are published.
@Suite struct SurfaceFailedExitRetentionTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    private static func failed(_ id: String, on machine: String = "vm-1", exitedAt: Date?) -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: .cloud(machine), kind: .terminal, key: id),
            title: "claude",
            detail: nil,
            lifecycle: .exited,
            agent: nil,
            remoteWorkspace: nil,
            port: nil,
            url: nil
        )
        resource.exit = SurfaceTerminalExit(
            kind: .exit,
            code: 1,
            exitedAtMilliseconds: exitedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
        resource.remoteViews = []
        return resource
    }

    private static func live(_ id: String) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("vm-1"), kind: .terminal, key: id),
            title: "zsh",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: nil,
            url: nil
        )
    }

    @Test func runsOlderThanTheWindowAreDroppedAndOtherRowsPassThrough() {
        let recent = Self.failed("recent", exitedAt: Self.now.addingTimeInterval(-60))
        let old = Self.failed("old", exitedAt: Self.now.addingTimeInterval(-SurfaceResource.failedExitRetentionWindow - 1))
        let kept = SurfaceResource.retainingFailedExits([Self.live("a"), old, recent], firstSeen: [:], now: Self.now)
        #expect(kept.map(\.id.key) == ["a", "recent"])
    }

    @Test func atMostTheLimitMostRecentRunsStayPerMachine() {
        let limit = SurfaceResource.failedExitPerMachineLimit
        let many = (0..<(limit + 5)).map { index in
            Self.failed("run\(index)", exitedAt: Self.now.addingTimeInterval(-Double(index) * 60))
        }
        let other = Self.failed("elsewhere", on: "vm-2", exitedAt: Self.now.addingTimeInterval(-3_600))
        let kept = SurfaceResource.retainingFailedExits(many.reversed() + [other], firstSeen: [:], now: Self.now)
        let onFirst = kept.filter { $0.machine == .cloud("vm-1") }.map(\.id.key)
        #expect(onFirst.count == limit)
        #expect(Set(onFirst) == Set((0..<limit).map { "run\($0)" }))
        #expect(kept.contains { $0.id.key == "elsewhere" })
    }

    @Test func aRunWithNoExitTimeAgesFromWhenItWasFirstSeen() {
        let undated = Self.failed("undated", exitedAt: nil)
        let first = SurfaceResource.updatingFailedExitFirstSeen([:], resources: [undated], now: Self.now)
        #expect(first[undated.id] == Self.now)
        #expect(SurfaceResource.retainingFailedExits([undated], firstSeen: first, now: Self.now).count == 1)

        // A later publish keeps the first sighting, not the later one.
        let later = Self.now.addingTimeInterval(SurfaceResource.failedExitRetentionWindow + 1)
        let second = SurfaceResource.updatingFailedExitFirstSeen(first, resources: [undated], now: later)
        #expect(second[undated.id] == Self.now)
        #expect(SurfaceResource.retainingFailedExits([undated], firstSeen: second, now: later).isEmpty)

        // A run that is gone is forgotten.
        #expect(SurfaceResource.updatingFailedExitFirstSeen(second, resources: [], now: later).isEmpty)
    }

    @Test func aFailedRunStillShownInATabIsNotRetentionsBusiness() {
        var shown = Self.failed("shown", exitedAt: Self.now.addingTimeInterval(-SurfaceResource.failedExitRetentionWindow * 2))
        shown.remoteViews = [
            SurfaceRemoteView(
                tabID: "tab_1",
                workspace: SurfaceRemoteWorkspace(id: "ws_1", name: "w", index: 0, focused: true),
                screenID: nil,
                paneID: "pane_1",
                name: nil,
                index: 0,
                focused: true,
                screenIndex: nil,
                paneIndex: nil
            ),
        ]
        #expect(SurfaceResource.retainingFailedExits([shown], firstSeen: [:], now: Self.now).count == 1)
    }
}
