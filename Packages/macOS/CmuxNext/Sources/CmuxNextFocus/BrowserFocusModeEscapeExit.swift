public import Foundation

/// Browser focus mode's exit gesture, ported from classic cmux
/// (`BrowserPanel.handleBrowserFocusModeKeyEvent`): two plain Escapes in a row.
///
/// The first plain Escape still reaches the page (a page's own Escape, such
/// as closing its dialog, keeps working) and arms the exit; the toolbar badge
/// then reads "Esc again to exit". A second plain Escape within
/// ``sequenceInterval`` leaves focus mode and is consumed. A late second
/// Escape re-arms instead. Any other key disarms. A held Escape's repeats and
/// a key-down seen twice (same timestamp) are consumed so they never count as
/// the second press. The rules are `cmux-focus-core`'s `escape_exit`
/// (`focus_escape_exit`); this value mirrors its state and calls it synchronously.
public struct BrowserFocusModeEscapeExit: Equatable {
    /// Classic cmux's window between the two presses.
    public static let sequenceInterval: TimeInterval = 1.6

    /// What the key dispatcher does with the key.
    public enum Outcome: Equatable {
        /// Not part of the gesture: route the key as usual.
        case pass
        /// The first Escape: the page gets it, the exit is armed.
        case forwardToPage
        /// The second Escape: leave focus mode for the tab; consume the key.
        case exit(tab: String)
        /// A repeat or a duplicate delivery of an Escape already counted.
        case consume
    }

    private struct Wire: Codable, Equatable {
        var armedTab: String?
        var armedAt: TimeInterval?
        var lastEscapeTimestamp: TimeInterval?
    }

    private var wire = Wire()

    /// The tab whose exit is armed, nil when none is.
    public var armedTab: String? { wire.armedTab }

    public init() {}

    /// Feeds one key-down.
    ///
    /// - Parameters:
    ///   - isPlainEscape: Escape with no modifier.
    ///   - isRepeat: The key-down is an auto-repeat.
    ///   - timestamp: The event's timestamp (seconds since boot).
    ///   - focusModeTab: The tab in browser focus mode that has the keyboard, nil when none.
    public mutating func handle(isPlainEscape: Bool, isRepeat: Bool, timestamp: TimeInterval, focusModeTab: String?) -> Outcome {
        // Every key-down comes here: one that is no focus-mode Escape skips the call when nothing
        // is armed, as the rule would only answer `pass` with the state it was sent.
        if (focusModeTab == nil || !isPlainEscape), wire == Wire() { return .pass }
        let key = Key(isPlainEscape: isPlainEscape, isRepeat: isRepeat, timestamp: timestamp, focusModeTab: focusModeTab)
        guard let response = FocusReducer.call("focus_escape_exit", Request(gesture: wire, key: key), as: Response.self) else {
            assertionFailure("focus_escape_exit refused")
            return .pass
        }
        wire = response.gesture
        switch response.outcome {
        case "forwardToPage": return .forwardToPage
        case "exit": return response.tab.map { .exit(tab: $0) } ?? .pass
        case "consume": return .consume
        default: return .pass
        }
    }

    /// Disarms (focus mode ended, focus moved, a non-Escape key).
    public mutating func reset() {
        wire = Wire()
    }

    private struct Key: Encodable {
        var isPlainEscape: Bool
        var isRepeat: Bool
        var timestamp: TimeInterval
        var focusModeTab: String?
    }

    private struct Request: Encodable {
        var gesture: Wire
        var key: Key
    }

    private struct Response: Decodable {
        var gesture: Wire
        var outcome: String
        var tab: String?
    }
}
