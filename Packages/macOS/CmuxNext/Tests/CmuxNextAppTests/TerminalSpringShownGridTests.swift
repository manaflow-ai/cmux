import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// The springs part of cmux-ad m29 (STATUS 14461/14468): in a split, close or zoom spring, a terminal that runs a
/// full-screen program (alternate screen) gets its PTY grid as Ghostty.app sends it during any motion: coalesced (the
/// newest at most once per 25 ms), and only grids of sizes a commit showed, never the spring's target. The last grid is
/// the landing's. Before: the spring's start sends the final grid in the key's turn and holds the surface at the final
/// size (``TerminalSurfaceView`` `restAt`), so the program jumps to its final size at once, and a band of terminal
/// background shows beside it on a shrink (or it is clipped on a grow) for the whole spring.
///
/// S4's rig on a display (`TerminalKeyResizeFrameTests.PaneScreen`, its daemon announcing each grid), p2 in the alternate
/// screen. One spring per case, stepped one 120 Hz frame per step and paced 8 ms apart in real time (the coalescer's
/// 25 ms windows close as on a display). After each commit, for p2: the grid its shown frame fits, the grids its PTY got
/// since, and the band (pane area wider than the surface) or clip (surface wider than the pane area), in points.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalSpringShownGridTests {
    typealias Rig = TerminalKeyResizeFrameTests

    enum Spring: String, CaseIterable, Sendable {
        /// Cmd-D on p2: p2 | p3, so p2 narrows.
        case split
        /// Cmd-W on p1: p2 takes the whole column, so p2 widens.
        case close
        /// Cmd-Shift-Enter on p2: p2 alone, zoomed.
        case zoom

        var layout: (ScreenLayout, zoomed: Bool) {
            switch self {
            case .split:
                let root: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                             b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
                return (.columns([LayoutColumn(id: "c0", width: 1, root: root)]), false)
            case .close:
                return (.columns([LayoutColumn(id: "c0", width: 1, root: .leaf("p2"))]), false)
            case .zoom:
                return (.columns([LayoutColumn(id: "c0", width: 1, root: .leaf("p2"))]), true)
            }
        }
    }

    @Test(arguments: Spring.allCases)
    func aFullScreenProgramGetsOnlyShownGridsCoalescedThroughASpringAndTheLandingGridLast(spring: Spring) async throws {
        let screen = try await Rig.PaneScreen(announcesGrids: true)
        defer { screen.close() }
        let session = screen.sessions[1], io = screen.ios[1]
        // p2 runs a full-screen program: the alternate screen, filled.
        let fill = Array(repeating: String(repeating: "#", count: 300), count: 120).joined(separator: "\r\n")
        io.send(.output(Data("\u{1b}[?1049h\u{1b}[H\(fill)".utf8)))
        let alternate = await Rig.commits(screen) { _ in Self.onAlternateScreen(session) }
        try #require(alternate, "SETUP: p2 never entered the alternate screen")
        await Rig.settle(screen)
        let start = try #require(session.surfaceView.fittedGrid, "SETUP: p2 fits no grid at rest")

        let before = io.resizes.count
        var seen = before
        var shown: Set<String> = []
        var unseen: [String] = [], lagging: [String] = []
        var arrivals: [ContinuousClock.Instant] = []
        var newest = start
        var staleSince: ContinuousClock.Instant?
        var bands: [CGFloat] = [], clips: [CGFloat] = []
        var frames = 0
        /// After a commit: what p2 shows, and each PTY grid that arrived since (it must be the grid of a shown frame).
        func record(moving: Bool) {
            let sample = Rig.GridSample(session), now = ContinuousClock.now
            if sample.showsItsOwnFrame, let fits = sample.fits { shown.insert(Rig.text(fits)) }
            for grid in io.resizes.dropFirst(seen) {
                let text = "\(grid.columns)x\(grid.rows)"
                if !shown.contains(text) { unseen.append("frame \(frames): \(text) before any commit showed it") }
                arrivals.append(now)
                newest = TerminalGridSize(columns: grid.columns, rows: grid.rows)
            }
            seen = io.resizes.count
            bands.append(max(0, sample.area.width - sample.surface.width))
            clips.append(max(0, sample.surface.width - sample.area.width))
            // While the pane moves, the shown grid reaches the program within two coalescing windows.
            guard moving, sample.showsItsOwnFrame, let fits = sample.fits, fits != newest else {
                staleSince = nil
                return
            }
            let since = staleSince ?? now
            staleSince = since
            if since.duration(to: now) > .milliseconds(60) {
                lagging.append("frame \(frames): shows \(Rig.text(fits)), the program has \(Rig.text(newest))")
            }
        }

        let (layout, zoomed) = spring.layout
        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout, zoomed: zoomed)])
        screen.root.syncWithModel()
        await Rig.commit()
        record(moving: true)
        var moving = true
        while moving, frames < 240 {
            moving = await Rig.stepFrame(screen).moving
            frames += 1
            record(moving: moving)
            try await Task.sleep(for: .milliseconds(8)) // a display's frame pace
        }
        await Rig.settle(screen)
        record(moving: false)

        let landing = session.surfaceView.fittedGrid
        let grids = io.resizes.dropFirst(before).map { "\($0.columns)x\($0.rows)" }
        let gaps = zip(arrivals.dropFirst(), arrivals).map { Rig.ms($1.duration(to: $0)) }
        let banded = bands.filter { $0 >= 1 }, clipped = clips.filter { $0 >= 1 }
        print("spring \(spring.rawValue): \(frames) frames; start \(Rig.text(start)), landing \(Rig.text(landing)); PTY grids \(grids) " +
              "gaps ms \(gaps); band in \(banded.count) frames (max \(banded.max() ?? 0) pt), clip in \(clipped.count) frames " +
              "(max \(clipped.max() ?? 0) pt); grids never shown \(unseen.count); lagging frames \(lagging.count)")
        try #require(frames > 3, "the \(spring.rawValue) did not spring")
        try #require(landing != start, "the \(spring.rawValue) did not change p2's grid")
        #expect(unseen.isEmpty, "\(unseen.count) grids went to the program at a size no commit showed: \(unseen.prefix(6))")
        #expect(grids.count >= 2, "the program got \(grids) during the spring: one jump, not coalesced grids while it moved")
        #expect(lagging.isEmpty, "\(lagging.count) frames showed a grid the program did not get within 60 ms: \(lagging.prefix(6))")
        #expect(grids.last == Rig.text(landing), "the program's last grid \(grids.last ?? "none") is not the landing's \(Rig.text(landing))")
    }

    static func onAlternateScreen(_ session: TerminalSession) -> Bool {
        guard let surface = session.surfaceView.surface else { return false }
        var metrics = ghostty_surface_grid_metrics_s()
        return ghostty_surface_grid_metrics(surface, &metrics) && metrics.alternate_screen
    }
}
