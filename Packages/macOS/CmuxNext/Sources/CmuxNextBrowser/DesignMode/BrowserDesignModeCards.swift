public import Foundation

/// Turns design mode's page messages into composer cards for one tab, remembering which
/// highlights it already sent so a snapshot that only scrolled sends nothing.
public nonisolated struct BrowserDesignModeCards: Sendable {
    public init() {}

    /// The cards for highlights in `message` (`{type: "snapshot", snapshot}`) not sent before.
    public mutating func receive(_ message: Data, pageURL: URL?) -> [BrowserDesignModeCard] {
        []
    }

    /// True for the page's `exit_requested` (Escape with nothing highlighted).
    public static func isExitRequest(_ message: Data) -> Bool { false }
}
