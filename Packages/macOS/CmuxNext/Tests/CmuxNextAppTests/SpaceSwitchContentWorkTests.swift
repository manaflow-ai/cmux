import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// The content half of a space switch (space-switch-3, F5): the workspace that shows takes its themes
/// once, and the titlebar takes a new title with no Auto Layout pass. Counts and frames, no clock.
@MainActor @Suite(.serialized)
struct SpaceSwitchContentWorkTests {
    /// A space switch showed its workspace to the themes twice: once in the switch's own turn
    /// (`WindowController.show`) and once more a turn later, from the window's room observation
    /// (`ThemeCoordinator.windowDidChange`). With 10 and with 413 workspaces in each space, each switch back
    /// and forth shows its content to the themes once. The printed line also gives the strip maps of the
    /// switch (the map at `PaneController.resume`): a measure, not a check.
    @Test(arguments: [20, 826])
    func aSpaceSwitchShowsItsContentToTheThemesOnce(total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, panes: true, registered: true)
        defer { bench.close() }
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        let themes = bench.services.themes
        for round in 0..<4 {
            let room = bench.rooms[(round + 1) % 2]
            let shows = themes.debugContentShows, maps = Self.stripMaps(bench)
            _ = try await bench.settledSwitch(to: room)
            #expect(bench.showsNow(room).content, "round \(round): the content area shows a workspace of \(room.rawValue)")
            print("SPACE-SWITCH-CONTENT n=\(total) round=\(round) content_shows=\(themes.debugContentShows - shows) strip_maps=\(Self.stripMaps(bench) - maps) mounted=\(bench.mounted)")
            #expect(themes.debugContentShows - shows == 1,
                    "round \(round) at \(total): one space switch showed its content to the themes \(themes.debugContentShows - shows) times")
        }
    }

    /// The strip maps of every mounted pane of the window so far.
    private static func stripMaps(_ bench: SpaceSwitchBench) -> Int {
        bench.controller.mountedContents.reduce(0) { sum, content in sum + content.panes.values.reduce(0) { $0 + $1.debugSnapshotRuns } }
    }

    /// The title label had an intrinsic size and four constraints, so each new title string (one per space
    /// switch) invalidated its content size and the window ran a constraint pass in the switch's first frame.
    /// The label has no intrinsic size and no constraint: the titlebar gives it the strip's width inside the
    /// side insets, and a new title moves no frame (the label centers and truncates its own text).
    @Test func aNewTitleNeedsNoConstraintPass() throws {
        let titlebar = TitlebarView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        let label = try #require(titlebar.subviews.first)
        titlebar.title = "Workspace 1"
        titlebar.layoutSubtreeIfNeeded()
        #expect(label.intrinsicContentSize.width == NSView.noIntrinsicMetric && label.intrinsicContentSize.height == NSView.noIntrinsicMetric,
                "the title label has the intrinsic size \(label.intrinsicContentSize): a new title invalidates it")
        #expect(label.translatesAutoresizingMaskIntoConstraints, "the title label is placed by constraints, not by the titlebar's layout")
        let insets = label.alignmentRectInsets, placed = label.frame
        #expect(placed.height > 0 && abs(placed.midY - titlebar.bounds.midY) <= 1, "the title is centered in the strip's height: \(placed) in \(titlebar.bounds)")
        #expect(abs(placed.minX + insets.left - Metrics.space5) <= 1 && abs(placed.maxX - insets.right - (titlebar.bounds.maxX - Metrics.space5)) <= 1,
                "the title has the strip's width inside the side insets: \(placed) in \(titlebar.bounds)")

        titlebar.title = String(repeating: "A long workspace name ", count: 20)
        titlebar.layoutSubtreeIfNeeded()
        #expect(label.frame == placed, "a new title moved the label: \(label.frame) after \(placed)")

        titlebar.setFrameSize(NSSize(width: 700, height: 28))
        titlebar.needsLayout = true
        titlebar.layoutSubtreeIfNeeded()
        #expect(abs(label.frame.maxX - insets.right - (700 - Metrics.space5)) <= 1, "the title follows the strip's width: \(label.frame)")
    }
}
