public import Foundation

/// The person's harness login choice for Cloud machines, kept per user (Leo, 2026-11-02: sign in at
/// most once per user): every later machine of that user, on any team, takes it with no prompt.
/// Written only by the person's own choices (their `--login` from their terminal or the palette,
/// or Yes on the first-login confirm), never by an agent's flag.
public nonisolated struct CloudHarnessLoginChoices {
    /// Where the choices are kept.
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func key(_ userID: String) -> String { "cmux.cloud.harnessLoginChoice." + userID }

    /// The choice `userID` made before; nil when none (or an unknown word).
    public func load(userID: String) -> CloudHarnessLoginDecision.Choice? {
        defaults.string(forKey: key(userID)).flatMap(CloudHarnessLoginDecision.Choice.init(rawValue:))
    }

    public func save(_ choice: CloudHarnessLoginDecision.Choice, userID: String) {
        defaults.set(choice.rawValue, forKey: key(userID))
    }
}

/// What a start asks of its harness login beyond the machine's facts: the run's `--login`, whether
/// the person gave it, and whether the run may show a prompt. A palette start is neither headless
/// nor flagged; `cmux cloud start-session` is headless, so with no login, no kept choice and no
/// `--login` it refuses at once instead of waiting on a prompt nobody sees.
public nonisolated struct CloudHarnessLoginAsk: Sendable, Equatable {
    public var requested: CloudHarnessLoginDecision.Choice?
    /// `requested` is the person's own (a run no agent asked for); only theirs is kept or stands in for the confirm.
    public var byPerson: Bool
    public var headless: Bool

    public init(requested: CloudHarnessLoginDecision.Choice? = nil, byPerson: Bool = false, headless: Bool = false) {
        (self.requested, self.byPerson, self.headless) = (requested, byPerson, headless)
    }

    /// A run's ask: its `--login` `word`, an `agent`'s run or the person's, and whether a prompt may
    /// show (only the palette's may; every CLI or agent run decides at once).
    public init(word: String?, agent: Bool, prompts: Bool) throws(Invalid) {
        self.init(requested: try Self.choice(word), byPerson: !agent, headless: !prompts)
    }

    /// `--login`'s word: `pass`, `machine` or `none` (any case); nil for no word, and
    /// ``Invalid`` for any other.
    public static func choice(_ word: String?) throws(Invalid) -> CloudHarnessLoginDecision.Choice? {
        guard let word = word?.trimmingCharacters(in: .whitespaces).lowercased(), !word.isEmpty else { return nil }
        guard let choice = CloudHarnessLoginDecision.Choice(rawValue: word) else { throw Invalid() }
        return choice
    }

    public struct Invalid: Error, Equatable {
        public init() {}
    }

    /// Puts this ask and `userID`'s kept choice on `decision`, and keeps the person's own `--login`
    /// as their choice for every later machine. An agent's flag only narrows what the person
    /// chose: its `pass` never overrides their kept `none` or `machine`.
    public func apply(to decision: inout CloudHarnessLoginDecision, userID: String?, choices: CloudHarnessLoginChoices = .init()) {
        let stored = userID.flatMap { choices.load(userID: $0) }
        var requested = requested
        if !byPerson, requested == .pass, stored == CloudHarnessLoginDecision.Choice.none || stored == .machine { requested = stored }
        (decision.requested, decision.requestedByPerson, decision.headless, decision.stored) = (requested, byPerson && requested != nil, headless, stored)
        if byPerson, let requested, let userID { choices.save(requested, userID: userID) }
    }
}

public extension CloudHarnessLoginChoices {
    /// Whether an automatic login copy (a rejected credential's recovery) may run on a machine whose
    /// start decided `decision`: never once that run, or the person's kept choice, said none or machine,
    /// and an agent's or a terminal's `--login pass` only where the person chose pass in cmux.
    static func allowsAutomaticCopy(_ decision: CloudHarnessLoginDecision?, stored: CloudHarnessLoginDecision.Choice?) -> Bool {
        let kept = decision?.stored ?? stored
        guard let requested = decision?.requested else { return kept != CloudHarnessLoginDecision.Choice.none && kept != .machine }
        return requested == .pass && (decision?.requestedByPerson == true || kept == .pass)
    }
}
