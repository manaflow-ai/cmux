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
    private var open: [String: Bool] = [:]

    /// The person's choice; nil when they never touched it.
    func isOpen(_ key: String) -> Bool? { open[key] }

    func set(_ key: String, _ value: Bool?) { open[key] = value }
}

extension EnvironmentValues {
    @Entry var chatDisclosures: ChatDisclosures?
}
