import Observation

/// Observable match state for a markdown panel's find session.
@MainActor
@Observable
final class MarkdownSearchState {
    var needle: String
    var selected: UInt?
    var total: UInt?

    init(needle: String = "") {
        self.needle = needle
    }
}
