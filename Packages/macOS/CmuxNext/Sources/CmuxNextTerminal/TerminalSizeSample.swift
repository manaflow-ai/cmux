import AppKit
import CmuxNextDesign
public import CmuxNextTerminalGeometry
import GhosttyNextKit

/// What a terminal's link to its PTY owner holds (``TerminalIO/linkGrids``).
public nonisolated struct TerminalLinkGrids: Sendable, Equatable {
    /// The grid the view last sent to the PTY on the live link; nil before the first.
    public var sent: TerminalGridSize?
    /// The grid the PTY owner last announced on the live link: its ack of a sent grid.
    public var acked: TerminalGridSize?
    /// A sent grid has not been announced yet.
    public var awaitingAck: Bool

    public init(sent: TerminalGridSize?, acked: TerminalGridSize?, awaitingAck: Bool) {
        self.sent = sent
        self.acked = acked
        self.awaitingAck = awaitingAck
    }
}

/// The sizes of one terminal at rest (``TerminalSizeInvariant``).
public nonisolated struct TerminalSizeSample: Sendable, Equatable, CustomStringConvertible {
    /// fit(bounds): the grid Ghostty fits into the surface's area in its host, from the area's
    /// size and the cell size (`ghostty_surface_fit_grid`).
    public var fit: TerminalGridSize?
    /// The grid of Ghostty's surface size (its last `ghostty_surface_set_size`).
    public var surface: TerminalGridSize?
    /// The grid the surface renders: the owner's announced grid once there is one.
    public var grid: TerminalGridSize?
    /// The link's grids; nil for an IO with no link (a bare local PTY).
    public var link: TerminalLinkGrids?

    public init(fit: TerminalGridSize?, surface: TerminalGridSize?, grid: TerminalGridSize?, link: TerminalLinkGrids?) {
        self.fit = fit
        self.surface = surface
        self.grid = grid
        self.link = link
    }

    /// One size everywhere: grid == fit(bounds) == Ghostty's surface == the PTY's == the daemon's. The surface
    /// renders only grids the daemon announced in its stream, so `grid` is the daemon's size as the view
    /// applied it; the link's record of the announcement (`acked`) is compared when it has one (an attach's
    /// grid arrives before its link is live and is not recorded there). A sent grid still waiting for its
    /// echo does not hold either: on one check it is on its way, but still waiting a settle later (the
    /// invariant confirms on a second check) it holds the next resize for an echo that cannot come.
    public var holds: Bool {
        guard let fit, surface == fit, grid == fit else { return false }
        guard let link else { return true }
        return link.sent == fit && (link.acked == nil || link.acked == fit) && !link.awaitingAck
    }

    /// What breaks the invariant, for the log.
    public var problem: String {
        guard let fit, surface == fit, grid == fit, let link, link.sent == fit, link.acked == nil || link.acked == fit else {
            return "sizes differ"
        }
        return link.awaitingAck ? "grid held across two checks a settle apart, waiting for an echo that cannot come"
            + (link.acked == nil ? " (no grid announced on the link since its attach)" : "") : "holds"
    }

    public var description: String {
        func text(_ grid: TerminalGridSize?) -> String { grid.map { "\($0.columns)x\($0.rows)" } ?? "none" }
        let link = link.map { " pty=\(text($0.sent)) daemon=\(text($0.acked)) awaiting_ack=\($0.awaitingAck)" } ?? " pty=local"
        return "fit=\(text(fit)) surface=\(text(surface)) grid=\(text(grid))" + link
    }
}

extension TerminalSession {
    /// The terminal's sizes for the size invariant, from values the view and its IO already hold (a
    /// few Ghostty getters, no daemon round trip). Nil when the invariant does not apply: no surface,
    /// the view is not shown, it does not set the terminal's grid (a follower, or another client sizes
    /// it, ``TerminalIO/appliesViewGrid(reporting:)``, or the view shows "Sized for"). `settled` is false while its pane is on a
    /// layout spring, its window resizes live or a grid report waits for a spring to land.
    public var sizeSample: (sample: TerminalSizeSample, settled: Bool)? {
        let surfaceView = surfaceView
        guard let surface = surfaceView.surface, surfaceView.isShown, surfaceView.ownsGeometry else { return nil }
        let link = io.linkGrids
        // Another client sizes the terminal, or a claim lost to the size policy ("Sized for"): not this view's grid.
        if link != nil, !io.appliesViewGrid(reporting: false) || view.sizedForText != nil { return nil }
        let area = view.surfaceSize(forHostSize: view.bounds.size)
        let pixels = surfaceView.convertToBacking(area)
        var columns: UInt16 = 0, rows: UInt16 = 0
        let fits = pixels.width >= 1 && pixels.height >= 1
            && ghostty_surface_fit_grid(surface, UInt32(pixels.width), UInt32(pixels.height), &columns, &rows)
        let size = ghostty_surface_size(surface)
        let sample = TerminalSizeSample(fit: fits ? TerminalGridSize(columns: Int(columns), rows: Int(rows)) : nil,
                                        surface: TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows)),
                                        grid: surfaceView.currentGrid, link: link)
        let settled = !surfaceView.isInPaneMotion && !surfaceView.isFollowingResizeGesture && !surfaceView.isHeldGridPending && surfaceView.window?.inLiveResize != true
        return (sample, settled)
    }
}
