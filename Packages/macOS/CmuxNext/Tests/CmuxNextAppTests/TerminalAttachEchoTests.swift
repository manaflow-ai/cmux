import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// The grid a new attach's own stream announces counts as the daemon's grid (cmux-ad P0 2026-10-31, the R3 DEBUG-check
/// owner's reading). The attach's `.grid` step reaches the machine while the attach is pending, and only a live link's
/// announcement was kept: `announcedSize` stayed nil, so the claim the replay makes (`syncGeometry`) of the size the
/// daemon already has added an echo the daemon never sends, and `ResizeCoordinator` held the next resize for its echo
/// wait (30 frames).
struct TerminalAttachEchoTests {
    typealias Machine = TerminalAttachMachine<Int>

    @Test func aClaimOfTheSizeTheAttachAnnouncedWaitsForNoEcho() throws {
        let size = CellSize(cols: 120, rows: 40)
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true)
        _ = machine.reduce(.resize(size))
        let attempt = try #require(machine.reduce(.start).compactMap { effect -> Int? in
            if case .open(let attempt, _) = effect { return attempt } else { return nil }
        }.first)
        _ = machine.reduce(.opened(5, attempt: attempt))
        // The attach's stream: its grid (the size it opened with), then its replay.
        _ = machine.reduce(.gridAnnounced(5, size))
        _ = machine.reduce(.replayDelivered(5))
        #expect(machine.liveLink == 5)
        #expect(machine.announcedSize == size, "the attach's own grid was dropped while it was pending")
        #expect(machine.echoesDue.isEmpty, "a claim of the daemon's own size waits for an echo that never comes: the next resize waits 30 frames")

        // The next resize is claimed at once and waits only for its own echo.
        let next = CellSize(cols: 100, rows: 40)
        let effects = machine.reduce(.resize(next))
        #expect(effects.contains { if case .claim(5, next) = $0 { true } else { false } })
        #expect(machine.echoesDue == [next])
    }
}
