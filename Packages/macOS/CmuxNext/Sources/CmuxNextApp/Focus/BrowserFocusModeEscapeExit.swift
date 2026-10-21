import Foundation

/// Browser focus mode's exit gesture, ported from classic cmux
/// (`BrowserPanel.handleBrowserFocusModeKeyEvent`): two plain Escapes in a row.
///
/// The first plain Escape still reaches the page (a page's own Escape, such
/// as closing its dialog, keeps working) and arms the exit; the toolbar badge
/// then reads "Esc again to exit". A second plain Escape within
/// ``sequenceInterval`` leaves focus mode and is consumed. A late second
/// Escape re-arms instead. Any other key disarms. A held Escape's repeats and
/// a key-down seen twice (same timestamp) are consumed so they never count as
/// the second press.
struct BrowserFocusModeEscapeExit: Equatable {
    /// Classic cmux's window between the two presses.
    static let sequenceInterval: TimeInterval = 1.6

    /// What the key dispatcher does with the key.
    enum Outcome: Equatable {
        /// Not part of the gesture: route the key as usual.
        case pass
        /// The first Escape: the page gets it, the exit is armed.
        case forwardToPage
        /// The second Escape: leave focus mode for the tab; consume the key.
        case exit(tab: String)
        /// A repeat or a duplicate delivery of an Escape already counted.
        case consume
    }

    /// The tab whose exit is armed, nil when none is.
    private(set) var armedTab: String?
    private var armedAt: TimeInterval?
    private var lastEscapeTimestamp: TimeInterval?

    /// Feeds one key-down.
    ///
    /// - Parameters:
    ///   - isPlainEscape: Escape with no modifier.
    ///   - isRepeat: The key-down is an auto-repeat.
    ///   - timestamp: The event's timestamp (seconds since boot).
    ///   - focusModeTab: The tab in browser focus mode that has the keyboard, nil when none.
    mutating func handle(isPlainEscape: Bool, isRepeat: Bool, timestamp: TimeInterval, focusModeTab: String?) -> Outcome {
        guard let tab = focusModeTab, isPlainEscape else {
            reset()
            return .pass
        }
        if isRepeat { return .consume }
        if lastEscapeTimestamp == timestamp { return .consume }
        lastEscapeTimestamp = timestamp
        if armedTab == tab, let armedAt, timestamp - armedAt <= Self.sequenceInterval {
            reset()
            return .exit(tab: tab)
        }
        armedTab = tab
        armedAt = timestamp
        return .forwardToPage
    }

    /// Disarms (focus mode ended, focus moved, a non-Escape key).
    mutating func reset() {
        armedTab = nil
        armedAt = nil
        lastEscapeTimestamp = nil
    }
}
