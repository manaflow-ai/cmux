import CmuxNextWindowRules

/// What the Rust Set Up card rules read and answer (`onboarding_first_run_card`, `_card_end`,
/// `_chief`, `_opacity`; cmux-window-rules `onboarding_first_run`): the stored state and launch facts out,
/// whether the card shows, starts, ends and which form Chief's chat shows back. The defaults
/// reads and writes stay in ``FirstRunSetup``; no rule does.
nonisolated enum FirstRunRules {
    nonisolated struct Launch: Encodable {
        var state: String?
        var isFirstRun: Bool
        var screenReader: Bool
        var skipsOnboarding: Bool
        var agentsShown: Bool
    }

    nonisolated struct LaunchAnswer: Decodable {
        var shows: Bool
        var begins: Bool
        var route: String
    }

    nonisolated struct Chief: Encodable {
        var shows: Bool
        var hidden: Bool
        var loaded: Bool
        var usesRoute: Bool
        var installable: Bool
        var auth: String?
        var awaitsConfirmation: Bool
    }

    nonisolated struct ChiefAnswer: Decodable {
        var needsChiefAgent: Bool
        var cardForm: String?
    }

    private nonisolated struct End: Encodable {
        var state: String?
        var completion: Bool
    }

    private nonisolated struct Ends: Decodable {
        var ends: Bool
    }

    private nonisolated struct Opacity: Encodable {
        var value: Double
    }

    private nonisolated struct SteppedOpacity: Decodable {
        var stepped: Double?
    }

    /// The Opacity slider's step for `value`, or nil when it is refused (outside 0...1, not finite:
    /// JSON carries no infinity or NaN, so those never reach Rust and are refused here too).
    static func steppedOpacity(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return WindowRules().call("onboarding_first_run_opacity", Opacity(value: value), as: SteppedOpacity.self)?.stepped
    }

    /// The launch's answer; when Rust does not answer, nothing shows or starts and the first-run windows run.
    static func launch(_ facts: Launch) -> LaunchAnswer {
        WindowRules().call("onboarding_first_run_card", facts, as: LaunchAnswer.self)
            ?? LaunchAnswer(shows: false, begins: false, route: "windows")
    }

    /// Whether Hide (`completion` false) or a completion ends the card; Hide always does when Rust does not answer.
    static func ends(state: String?, completion: Bool) -> Bool {
        WindowRules().call("onboarding_first_run_card_end", End(state: state, completion: completion), as: Ends.self)?.ends
            ?? !completion
    }

    /// Chief's card; none when Rust does not answer.
    static func chief(_ facts: Chief) -> ChiefAnswer {
        WindowRules().call("onboarding_first_run_chief", facts, as: ChiefAnswer.self)
            ?? ChiefAnswer(needsChiefAgent: false, cardForm: nil)
    }
}

extension FirstRunSetup.Route {
    init(wire: String) {
        switch wire {
        case "startCard": self = .startCard
        case "cardOwns": self = .cardOwns
        default: self = .windows
        }
    }
}
