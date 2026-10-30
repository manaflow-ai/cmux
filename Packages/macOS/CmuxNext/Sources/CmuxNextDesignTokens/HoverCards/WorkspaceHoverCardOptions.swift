package import Foundation

/// What a sidebar workspace hover card shows (u3320: "We also need to make it more
/// customizable"), from `sidebar.hoverCards.*` in cmux.json; the settings applier writes it into
/// `DesignSettings.workspaceHoverCard`. Each layout is one of the designs in
/// plans/cmux-next/hover-card-history/DESIGN.md.
public nonisolated struct WorkspaceHoverCardOptions: Sendable, Hashable {
    /// The card's design.
    public enum Layout: String, Sendable, Hashable, CaseIterable {
        /// The default: the title, status and a stats line, the workspace's facts, then the
        /// scrollable history (prompts, starts, waits, finished turns), newest first.
        case timeline
        /// The facts card with the last three moments under it, no scrolling.
        case compact
        /// The history alone, taller and wider, each prompt up to three lines.
        case log
        /// The facts card as it was before the history (2026-10-19).
        case classic
        /// The title, status and the last prompt only.
        case minimal
    }

    public var layout: Layout = .timeline
    /// Running times: the status's and a command's elapsed time, and the stats line.
    public var showsTimings = true
    /// Prompts the person sent, and starts of work, in the history.
    public var showsPrompts = true
    /// Waits for the person and finished or failed turns in the history.
    public var showsWaiting = true
    /// The branch and the pull request.
    public var showsGit = true
    /// The workspace's listening ports.
    public var showsPorts = true
    /// The most history lines the card lists (the rest scroll away, oldest first).
    public var maxRows = 20
    /// The range `maxRows` is clamped to.
    public static let maxRowsRange: ClosedRange<Int> = 1...100

    public init() {}

    /// How many lines the history lists for this layout: none for classic, three at most for
    /// compact, one prompt for minimal.
    public var historyRows: Int {
        switch layout {
        case .classic: 0
        case .compact: min(3, maxRows)
        case .minimal: 0
        case .timeline, .log: maxRows
        }
    }
}
