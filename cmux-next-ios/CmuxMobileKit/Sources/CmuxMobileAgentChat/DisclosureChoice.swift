import Observation
import SwiftUI

/// A row that opens on its own (a live thought shows its last lines) until
/// the person taps it: from then on their choice holds, so a tap always
/// closes what is open. A live thought used to keep its text on screen
/// after a tap with the chevron turned to closed.
struct DisclosureChoice: Equatable {
    /// The person's choice; nil follows `automatic`.
    private(set) var chosen: Bool?

    init(chosen: Bool? = nil) {
        self.chosen = chosen
    }

    func isOpen(automatic: Bool) -> Bool { chosen ?? automatic }

    mutating func toggle(automatic: Bool) {
        chosen = !isOpen(automatic: automatic)
    }
}

/// Rows a person opened or closed in a transcript whose rows are reused cells (tool rows,
/// groups, thoughts, long diffs), by row key, so a row that scrolls away and back keeps it.
@MainActor
@Observable
final class ChatDisclosures {
    @ObservationIgnored private var open: [String: Bool] = [:]
    /// Bumps on every change (the transcript swaps native and SwiftUI rows on it).
    private(set) var revision = 0

    /// The person's choice; nil when they never touched it.
    func isOpen(_ key: String) -> Bool? {
        access(keyPath: \.revision)
        return open[key]
    }

    func set(_ key: String, _ value: Bool?) {
        guard open[key] != value else { return }
        open[key] = value
        revision &+= 1
    }

    /// Disclosures opening or closing on the person's tap (`toggleDisclosure`): their rows draw
    /// in SwiftUI until the animation completes, so every disclosure plays the same reveal. A
    /// native row (a finished tool row, group or thought at rest) swapped to its open SwiftUI
    /// view with nothing to animate, so it opened at once while SwiftUI rows animated, and an
    /// open row swapped back to native mid-close.
    /// Counted per key: a second tap inside the spring starts a second settle, and the first
    /// one's completion must not end it early.
    @ObservationIgnored private var settling: [String: Int] = [:]

    func isSettling(_ key: String) -> Bool {
        access(keyPath: \.revision)
        return settling[key, default: 0] > 0
    }

    func settle(_ key: String, _ on: Bool) {
        let before = settling[key, default: 0]
        let after = on ? before + 1 : max(0, before - 1)
        settling[key] = after == 0 ? nil : after
        if (before == 0) != (after == 0) { revision &+= 1 }
    }
}

extension EnvironmentValues {
    @Entry var chatDisclosures: ChatDisclosures?
}

extension DisclosureChoice {
    /// The end of `text` that fits three lines: its last three lines, and of a long last
    /// line only its end, cut at a word ("…" says text comes before it).
    static func liveTail(of text: String, lines: Int = 3, characters: Int = 240) -> String {
        // Only the end is read: a long live thought is split again on every chunk.
        let window = text.suffix(characters * 2)
        let parts = window.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = parts.suffix(lines)
        var tail = kept.joined(separator: "\n")
        var cut = parts.count > kept.count || window.startIndex != text.startIndex
        if tail.count > characters {
            let end = tail.suffix(characters)
            tail = String(end.firstIndex(where: \.isWhitespace).map { end[$0...].drop(while: \.isWhitespace) } ?? end)
            cut = true
        }
        return cut ? "…" + tail : tail
    }
}
