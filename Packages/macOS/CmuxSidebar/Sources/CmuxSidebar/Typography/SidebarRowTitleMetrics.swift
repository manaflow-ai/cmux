public import AppKit
public import SwiftUI

/// Type metrics for one workspace row title in the sidebar.
///
/// Both sidebar renderers (the AppKit table cells and the SwiftUI rows) build
/// this from the two title settings, so a title occupies the same box and
/// truncates the same way whichever one draws it.
///
/// The line limit is the value the rest of the metrics are derived from rather
/// than an argument passed alongside them: a title truncated at its end while
/// being laid out on one line, or in the middle while wrapping, is a mismatch
/// the two renderers used to be free to make independently.
public struct SidebarRowTitleMetrics: Equatable, Sendable {
    /// Base point size for a workspace row title, before the sidebar font scale
    /// and the global font magnification.
    ///
    /// Half a point smaller than the size cmux shipped before: at the default
    /// sidebar width the old size cut most titles inside a dozen characters,
    /// and the row is a label, not body text.
    public static let fontSize: CGFloat = 12

    /// Lines a wrapped title may occupy when `sidebar.wrapWorkspaceTitles` is on.
    public static let maxWrappedLines = 8

    /// Lines a title may occupy when only `sidebar.twoLineWorkspaceTitles` is on.
    public static let twoLineLines = 2

    /// Lines this title may occupy.
    public let lineLimit: Int

    /// `wrapsTitles` keeps its shipped meaning (show the whole title, up to
    /// `maxWrappedLines`). `usesTwoLines` is the middle setting: a second line
    /// for the titles that need one, still bounded so a long title cannot push
    /// its neighbours off screen.
    public init(wrapsTitles: Bool, usesTwoLines: Bool) {
        if wrapsTitles {
            lineLimit = Self.maxWrappedLines
        } else {
            lineLimit = usesTwoLines ? Self.twoLineLines : 1
        }
    }

    /// Metrics for a title already known to be laid out on `lineLimit` lines.
    public init(lineLimit: Int) {
        self.lineLimit = max(1, lineLimit)
    }

    /// Whether this title is shortened in its middle.
    ///
    /// A single line is: the start of a title and its distinctive tail are both
    /// worth more than the words in between, so "Fix cmux pane focus indicator
    /// flicker" reads as "Fix cmux pa…r flicker" and "cmux-remote-status @host"
    /// keeps the host it points at. Titles on more than one line truncate at the
    /// end of the last line, where the earlier lines already carry the start.
    public var truncatesMiddle: Bool {
        lineLimit == 1
    }

    public var appKitLineBreakMode: NSLineBreakMode {
        if truncatesMiddle {
            return .byTruncatingMiddle
        }
        // Word wrapping with no truncation is only safe when the limit is high
        // enough to show a whole title; a two-line title has to show the reader
        // that something was cut.
        return lineLimit >= Self.maxWrappedLines ? .byWordWrapping : .byTruncatingTail
    }

    public var swiftUITruncationMode: Text.TruncationMode {
        truncatesMiddle ? .middle : .tail
    }
}
