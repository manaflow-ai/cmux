import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// cmux-ad m29, rule from the RESIZE OWNER (frame-owner-s4's point 4): every grid a terminal's program gets during a
/// divider drag is the grid of a size a commit showed on screen. In a drag the size asked of Ghostty can be up to two
/// refreshes ahead of the size shown with its frame, and with the 25 ms coalescing the newest asked size can be one that
/// never shows, so the program would redraw at a size the person never sees. While the divider moves the program also
/// gets a new grid at least every few windows, and the last grid goes at the release.
///
/// S4's rig on a display (`TerminalKeyResizeFrameTests.PaneScreen`, its daemon announcing each grid); a drag of the split's
/// divider 6 pt left per frame for 40 frames, paced 12 ms apart in real time (the coalescer's 25 ms windows close as in a
/// person's drag), then the release and its landing. After each commit the grid each shown frame fits is recorded.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalDragShownGridTests {
    typealias Rig = TerminalKeyResizeFrameTests

    @Test func everyGridADragSendsIsTheGridOfAShownFrame() async throws {
        let screen = try await Rig.PaneScreen(announcesGrids: true)
        defer { screen.close() }
        await Rig.settle(screen)
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        let before = screen.ios.map { $0.resizes.count }
        var shown = Array(repeating: Set<String>(), count: screen.sessions.count)
        var seen = before, unseen: [String] = []
        // Per commit: the grids each shown frame fits so far, then each PTY grid that arrived since the last commit must be
        // one of them (frame-owner-s4: a drag step that asks a new size in the turn of a landing must send the landed grid,
        // not the new ask, which no commit has shown yet).
        func record() {
            for (index, session) in screen.sessions.enumerated() {
                let sample = Rig.GridSample(session)
                if sample.showsItsOwnFrame, let fits = sample.fits { shown[index].insert(Rig.text(fits)) }
                let resizes = screen.ios[index].resizes
                for grid in resizes.dropFirst(seen[index]).map({ "\($0.columns)x\($0.rows)" }) where !shown[index].contains(grid) {
                    unseen.append("p\(index + 1): \(grid) before any commit showed it (shown: \(shown[index].sorted().prefix(6)))")
                }
                seen[index] = resizes.count
            }
        }
        record()

        view.handleDrag(kind: .split("x"), event: .began(start, []))
        let moves = 40
        for move in 1...moves {
            view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(move) * 6, y: start.y), []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await Rig.commit()
            record()
            try await Task.sleep(for: .milliseconds(12)) // the drag's own pace
        }
        let duringDrag = zip(screen.ios.map { $0.resizes.count }, before).map { $0 - $1 }
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - CGFloat(moves) * 6, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true, steps = 0
        while moving || steps < 6, steps < 240 {
            moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the release's frames
            await Rig.commit()
            record()
            steps += 1
        }
        await Rig.settle(screen)
        record()

        let rested = zip(screen.sessions, screen.ios).map { session, io in
            (fits: session.surfaceView.fittedGrid.map { "\($0.columns)x\($0.rows)" }, newest: io.resizes.last.map { "\($0.columns)x\($0.rows)" })
        }
        print("drag shown grids: PTY grids during the drag \(duringDrag); grids never shown \(unseen.count); rested \(rested)")
        #expect(duringDrag.allSatisfy { $0 >= 2 }, "a program got \(duringDrag) grids while the divider moved: it waits for the landing")
        #expect(unseen.isEmpty, "\(unseen.count) grids went to a program at a size no commit showed: \(unseen.prefix(6))")
        #expect(rested.allSatisfy { $0.fits == $0.newest }, "after the landing a program's newest grid is not its view's: \(rested)")
    }
}
