public import Foundation

/// Omnibox edits the profile's AutocompleteActionPredictor could not learn yet. Chromium loads the
/// predictor's database after start-up (a BEST_EFFORT task), and until then `OnOmniboxOpenedUrl` drops the
/// hit: on cmux-lawrence-2 the 3 Enters a person makes in the first ~2 s after launch taught it nothing
/// (bench `omnibar`, 2026-11-18). The fork answers 0 for such an end (`cmux_omnibox_preload_opened`), so
/// the edit is kept here and taught again, in order, at the start of a later edit of the same profile.
public nonisolated struct OmniboxPendingLearns: Sendable {
    /// One text the edit showed matches for (`OnTextChanged`): the predictor learns a hit for each.
    public struct Registration: Equatable, Sendable {
        public var text: String
        public var matches: [OmniboxPreloadMatch]

        public init(text: String, matches: [OmniboxPreloadMatch]) {
            self.text = text
            self.matches = matches
        }
    }

    /// One ended edit: the texts it registered, in order, and the URL it opened.
    public struct Learn: Equatable, Sendable {
        public var registrations: [Registration]
        public var opened: URL

        public init(registrations: [Registration], opened: URL) {
            self.registrations = registrations
            self.opened = opened
        }

        public init(text: String, matches: [OmniboxPreloadMatch], opened: URL) {
            self.init(registrations: [Registration(text: text, matches: matches)], opened: opened)
        }

        /// The last text typed.
        public var text: String { registrations.last?.text ?? "" }
    }

    /// At most this many edits wait (the oldest go first): a database that never loads keeps no unbounded list.
    public static let capacity = 16
    /// At most this many texts per edit (the latest kept): the ones nearest what was opened.
    public static let registrationsPerLearn = 64
    public private(set) var learns: [Learn] = []

    public init() {}

    /// The end of an edit that teaches the predictor: `send` passes it on and answers the fork's result
    /// (0 while the predictor's database loads).
    public mutating func ended(_ learn: Learn, send: (Learn) -> Int32) {
        guard send(learn) == 0 else { return }
        var kept = learn
        kept.registrations = Array(learn.registrations.suffix(Self.registrationsPerLearn))
        learns.append(kept)
        if learns.count > Self.capacity { learns.removeFirst(learns.count - Self.capacity) }
    }

    /// Before a new edit: teaches the kept edits in order. An edit `allowed` refuses is dropped untaught;
    /// `register` shows one text's matches to the predictor (`OnTextChanged`), `open` ends the edit with its
    /// URL (`OnOmniboxOpenedUrl`).
    public mutating func replay(allowed: (Learn) -> Bool = { _ in true }, register: (Registration) -> Void,
                                open: (Learn) -> Int32) {
        learns.removeAll { !allowed($0) }
        while let learn = learns.first {
            learn.registrations.forEach(register)
            // 0: still loading (the fork forgot the matches just registered); the rest wait, in order.
            guard open(learn) != 0 else { return }
            learns.removeFirst()
        }
    }
}
