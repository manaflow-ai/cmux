import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// `PaneCommitMotionTests`, a split whose new pane waits for its terminal.
///
/// A split's new terminal pane shows no view in the frame of its key: its terminal is made after that frame, and the
/// pane's area waits for it. Over a window that is not opaque a terminal paints no ground of its own, so the area
/// waits with no ground. The split moves there as it does in an opaque window, and the terminal's view comes into
/// the pane while the pane moves.
extension PaneCommitMotionTests {
    /// The windows of the split's row: what is under the panes.
    nonisolated static let waitLooks = ["a picture", "see-through, no picture", "opaque"]
    nonisolated static let waitCounts = [2, 30]

    /// The app's write of a pane's wait for its terminal on the pane's area (`ThemeCoordinator.applyPaneBackground`).
    /// `ground`: what the terminal paints when it comes; nil over a window that is not opaque
    /// (`aPaneThatWaitsForItsTerminalRidesByTheAppsOwnWrite` holds that write itself).
    static func write(waits: Bool, ground: CGColor?, on area: PaneContentAreaView) {
        area.waitsForContent = waits
        area.waitingGround = waits ? ground : nil
    }

    /// A split of 2 and of 30 panes whose new pane waits for its terminal, over a window's picture, in a see-through
    /// window with no picture and in an opaque window. The new pane's content is as the app builds it: a container
    /// with one content area that fills it, and no view in the area yet. The split moves: the new pane goes from no
    /// room to its rect. 3 frames into the move the terminal's view comes into the area (the suite's riding double)
    /// and the wait ends: the pane's move goes on as it was, with no second act. The motion ends by the frame clock
    /// in a split's time.
    @Test(arguments: waitLooks, waitCounts)
    func aSplitWhoseNewPaneWaitsForItsTerminalHasItsWholeTime(_ look: String, _ count: Int) throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(count)), focused: "p", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        if look != "opaque" { _ = Self.picture(under: harness, gap: look == "a picture" ? nil : "noPicture") }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let had = Set(harness.provider.contents.keys)
        harness.model.apply(screens: Commit.screen(Self.tree(count + 1)))
        harness.root.syncWithModel()
        let made = harness.provider.contents.filter { !had.contains($0.key) }
        let new = try #require(made.count == 1 ? made.first : nil,
                               "SETUP: the split made \(made.count) pane contents before the frame that shows it, not 1")
        let area = PaneContentAreaView(frame: new.value.bounds)
        area.autoresizingMask = [.width, .height]
        new.value.addSubview(area)
        let ground: CGColor? = look == "opaque" ? CGColor(gray: 0.1, alpha: 1) : nil
        Self.write(waits: true, ground: ground, on: area)
        _ = harness.root.advanceFrame(Self.dt)

        let host = try #require(Self.hosts(of: screen)[new.key], "SETUP: the split's new pane has no host")
        let layer = try #require(host.layer, "SETUP: the new pane's host has no layer")
        let room = area.bounds
        try #require(room.width >= 1 && room.height >= 1 && new.value.paneCommitMotionTop == nil,
                     "SETUP: the new pane's area has the size \(room.size) and a view on top: the test does not reach the case")
        let move = Self.move(of: layer)
        #expect(Self.inFlight(screen) && move.moves,
                "over \(look) a split of \(count) panes whose new pane waits for its terminal shows in one frame: the new pane has no move")
        guard move.moves else { return }
        #expect(min(move.start.width, move.start.height) < 0.5 && Commit.near(move.end, layer.frame),
                "the new pane's move goes from \(move.start) to \(move.end); it starts with no room and ends at the pane's rect \(layer.frame)")
        let keys = Set(layer.animationKeys() ?? [])

        for _ in 0..<2 { _ = harness.root.advanceFrame(Self.dt) }
        try #require(Self.inFlight(screen), "SETUP: the split's move ended in 3 frames")
        let terminal = Commit.Content()
        terminal.frame = area.bounds
        terminal.autoresizingMask = [.width, .height]
        area.addSubview(terminal)
        Self.write(waits: false, ground: nil, on: area)
        _ = harness.root.advanceFrame(Self.dt)
        let after = Self.move(of: layer)
        let acts = Self.acts(on: screen)
        #expect(Set(layer.animationKeys() ?? []) == keys && after.start == move.start && after.end == move.end && acts.count == 1,
                "the terminal's view came 3 frames into the move: the new pane's move is now from \(after.start) to \(after.end) with the acts \(acts); it was from \(move.start) to \(move.end) with 1 act")

        // Three frames were stepped after the frame that showed the split.
        var ticks = 3
        while Self.inFlight(screen), ticks < Commit.frames {
            _ = harness.root.advanceFrame(Self.dt)
            ticks += 1
        }
        let spent = Double(ticks) * Self.dt
        #expect(spent >= Self.split.time / 2 && spent <= Self.split.time + 2 * Self.dt,
                "the motion ended \(spent) s after the frame that showed the split; a split's time is \(Self.split.time) s")
        #expect(new.value.paneRidesCommitMotion, "after the move the pane with its terminal's view does not ride")
    }
}
