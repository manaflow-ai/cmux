import Foundation

/// The byte-faithful terminal payload one of the Debug menu's stress-content
/// tab openers streams into a freshly created tab.
///
/// `AppDelegate.openDebugScrollbackTab(_:)` and `openDebugLoremTab(_:)` create
/// a tab and stream a large body of text into it to exercise scrollback /
/// rendering under load. The tab creation, config read, and surface streaming
/// are live-app concerns that stay in the app target; the deterministic *text*
/// each opener streams is a pure function of a couple of inputs, so it is
/// modeled here as an instantiable value whose ``text`` it produces, testable
/// byte-for-byte without an app instance.
///
/// The value is the content request (`.scrollback` carrying the configured
/// limit, or `.lorem`); reading ``text`` runs the byte-faithful builder. Both
/// reproduce the legacy inline builders exactly (the `%06d` field-width floor,
/// the byte-target clamps, and the `%04d`-prefixed Lorem lines), so swapping
/// the app call sites onto this type is a faithful lift, not a behavior change.
public enum DebugTerminalTabContent: Sendable, Equatable {
    /// A run of `scrollback %06d` lines sized to the doubled, clamped scrollback
    /// limit, used to fill the scrollback buffer.
    ///
    /// - Parameter scrollbackLimit: The terminal's configured scrollback limit
    ///   in bytes (a negative value is treated as zero, matching the legacy
    ///   `max(_, 0)`).
    case scrollback(scrollbackLimit: Int)

    /// A fixed run of `%04d`-indexed Lorem lines.
    case lorem

    /// The minimum payload size, in bytes, the scrollback content targets.
    public static let scrollbackMinimumTargetBytes = 2_000_000

    /// The maximum payload size, in bytes, the scrollback content targets.
    public static let scrollbackMaximumTargetBytes = 200_000_000

    /// The minimum number of scrollback lines emitted regardless of the byte
    /// target.
    public static let scrollbackMinimumLineCount = 2000

    /// The number of Lorem lines the `.lorem` content emits.
    public static let loremLineCount = 2000

    /// The repeated Lorem sentence each `.lorem` line carries after its index.
    public static let loremBaseSentence =
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."

    /// The byte-faithful, newline-terminated text to stream to a terminal
    /// surface for this content.
    public var text: String {
        switch self {
        case .scrollback(let scrollbackLimit):
            return Self.scrollbackCommand(scrollbackLimit: scrollbackLimit)
        case .lorem:
            return Self.loremPayload()
        }
    }

    /// Builds the `awk` command (with its trailing newline) that emits at least
    /// the clamped byte target of `scrollback %06d` lines.
    ///
    /// The byte target is the configured scrollback limit doubled, clamped into
    /// `[scrollbackMinimumTargetBytes, scrollbackMaximumTargetBytes]`. The line
    /// count is the target divided by the width of a 6-digit line, floored at
    /// `scrollbackMinimumLineCount`; the `%06d` field width guarantees lines are
    /// never narrower than that estimate, so the emitted payload always reaches
    /// the byte target.
    private static func scrollbackCommand(scrollbackLimit: Int) -> String {
        let effectiveLimit = max(scrollbackLimit, 0)
        let doubledLimit = min(effectiveLimit, scrollbackMaximumTargetBytes / 2) * 2
        let targetBytes = min(max(doubledLimit, scrollbackMinimumTargetBytes), scrollbackMaximumTargetBytes)
        // `%06d` guarantees at least a 6-digit field width. Any lines beyond
        // 999,999 only get wider, so this conservative floor always emits at
        // least `targetBytes` without oscillating at digit-count boundaries.
        let baseBytesPerLine = "scrollback 000000\n".utf8.count
        let lineCount = max((targetBytes + baseBytesPerLine - 1) / baseBytesPerLine, scrollbackMinimumLineCount)

        return #"awk 'BEGIN { for (i = 1; i <= \#(lineCount); ++i) printf "scrollback %06d\n", i }'"# + "\n"
    }

    /// Builds the Lorem payload: `loremLineCount` lines, each a `%04d` index
    /// followed by `loremBaseSentence`, joined by newlines with a trailing
    /// newline.
    private static func loremPayload() -> String {
        var lines: [String] = []
        lines.reserveCapacity(loremLineCount)
        for index in 1...loremLineCount {
            lines.append(String(format: "%04d %@", index, loremBaseSentence))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
