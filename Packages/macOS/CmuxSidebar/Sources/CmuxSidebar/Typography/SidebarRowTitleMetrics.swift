public import AppKit
public import SwiftUI

/// Type metrics for workspace row titles in the sidebar.
///
/// Both sidebar renderers (the AppKit table cells and the SwiftUI rows) read
/// these, so a title occupies the same box and truncates the same way whichever
/// one draws it.
public enum SidebarRowTitleMetrics {
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

    /// Lines a workspace title may occupy.
    ///
    /// `wrapsTitles` keeps its shipped meaning (show the whole title, up to
    /// `maxWrappedLines`). `usesTwoLines` is the middle setting: a second line
    /// for the titles that need one, still bounded so a long title cannot push
    /// its neighbours off screen.
    public static func lineLimit(wrapsTitles: Bool, usesTwoLines: Bool) -> Int {
        if wrapsTitles {
            return maxWrappedLines
        }
        return usesTwoLines ? twoLineLines : 1
    }

    /// How a title that does not fit its row is shortened.
    ///
    /// A single line truncates in the middle: the start of a title and its
    /// distinctive tail are both worth more than the words in between, so
    /// "Fix cmux pane focus indicator flicker" reads as "Fix cmux pa…r flicker"
    /// and "cmux-remote-status @host" keeps the host it points at. Wrapped
    /// titles truncate at the end of the last line, where the earlier lines
    /// already carry the start.
    public static func truncatesMiddle(lineLimit: Int) -> Bool {
        lineLimit == 1
    }

    public static func appKitLineBreakMode(lineLimit: Int) -> NSLineBreakMode {
        if truncatesMiddle(lineLimit: lineLimit) {
            return .byTruncatingMiddle
        }
        // Word wrapping with no truncation is only safe when the limit is high
        // enough to show a whole title; a two-line title has to show the reader
        // that something was cut.
        return lineLimit >= maxWrappedLines ? .byWordWrapping : .byTruncatingTail
    }

    public static func swiftUITruncationMode(lineLimit: Int) -> Text.TruncationMode {
        truncatesMiddle(lineLimit: lineLimit) ? .middle : .tail
    }
}
