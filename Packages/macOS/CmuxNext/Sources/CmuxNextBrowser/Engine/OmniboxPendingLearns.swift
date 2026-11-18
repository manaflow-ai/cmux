public import Foundation

/// Omnibox edits the profile's AutocompleteActionPredictor could not learn yet. Chromium loads the
/// predictor's database after start-up (a BEST_EFFORT task), and until then `OnOmniboxOpenedUrl` drops the
/// hit: on cmux-lawrence-2 the 3 Enters a person makes in the first ~2 s after launch taught it nothing
/// (bench `omnibar`, 2026-11-18). The fork answers 0 for such an end (`cmux_omnibox_preload_opened`), so
/// the edit is kept here and taught again, in order, at the start of a later edit of the same profile.
public nonisolated struct OmniboxPendingLearns: Sendable {
    /// One ended edit: the typed text, the matches it showed (the default first) and the URL it opened.
    public struct Learn: Equatable, Sendable {
        public var text: String
        public var matches: [OmniboxPreloadMatch]
        public var opened: URL

        public init(text: String, matches: [OmniboxPreloadMatch], opened: URL) {
            self.text = text
            self.matches = matches
            self.opened = opened
        }
    }

    /// At most this many wait (the oldest go first): a database that never loads keeps no unbounded list.
    public static let capacity = 16
    public private(set) var learns: [Learn] = []

    public init() {}

    /// The end of an edit that teaches the predictor: `send` passes it on and answers the fork's result
    /// (0 while the predictor's database loads).
    public mutating func ended(_ learn: Learn, send: (Learn) -> Int32) {
        _ = send(learn)
    }

    /// Before a new edit: teaches the kept edits in order. `register` shows the edit's matches to the
    /// predictor (`OnTextChanged`), `open` ends it with its URL (`OnOmniboxOpenedUrl`).
    public mutating func replay(register: (Learn) -> Void, open: (Learn) -> Int32) {}
}
