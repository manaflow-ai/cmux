import Foundation

/// One find-window result: a window name, a pane title, or a line of pane content.
struct RemoteTmuxFindWindowResult: Identifiable, Equatable, Sendable {
    enum Match: Equatable, Sendable {
        /// The window name matched; `highlights` are character ranges in it.
        case windowName(highlights: [Range<Int>])
        /// The pane title matched; `highlights` are character ranges in it.
        case paneTitle(title: String, highlights: [Range<Int>])
        /// A line of the pane's history or screen matched.
        case content(RemoteTmuxFindWindowContentHit)
        /// No query: the window is listed so the panel doubles as a window list.
        case window
    }

    let id: String
    let candidate: RemoteTmuxFindWindowCandidate
    let match: Match
    /// Higher is better; only fuzzy name and title matches carry a score.
    let score: Int
}

/// A matched line, cut down to a snippet around the match.
struct RemoteTmuxFindWindowContentHit: Equatable, Sendable {
    let snippet: String
    /// Character ranges of the match within ``snippet``.
    let highlights: [Range<Int>]
    /// The text the pattern matched, used as the surface find needle on jump.
    let matchedText: String
    /// Lines between this one and the pane's bottom line; 0 is the bottom line.
    let linesFromBottom: Int
    /// The most terminal rows between this line's first row and the pane's bottom row,
    /// counting the rows long lines wrap onto; 0 is the bottom row.
    let rowsFromBottom: Int

    /// Whether the match may be older than the rows the attach seed put on the surface,
    /// so the surface's own find needs the full history loaded first.
    var isBeyondAttachSeed: Bool {
        rowsFromBottom >= RemoteTmuxControlConnection.attachSeedHistoryRows
    }
}
