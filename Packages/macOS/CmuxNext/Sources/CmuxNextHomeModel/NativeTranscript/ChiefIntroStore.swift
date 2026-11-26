public import CmuxHomeCore
public import Foundation

/// Which intro still has to show on a Chief's empty conversation, and records the ones shown.
///
/// The intro is a fixed message from the Chief on its empty conversation, and it is contextual
/// (the user, 2026-10-27): the person's only Chief gives the ``ChiefIntroKind/welcome`` once per
/// install; a Chief made while other Chiefs exist asks what it should focus on
/// (``ChiefIntroKind/askFocus``), once per Chief. An intro is marked shown the moment it shows, so
/// it never returns, even when the person ignores it.
/// The rules are `welcome.intro` and `welcome.markShown` (cmux-home-rules); this store reads and writes
/// the defaults they name.
public struct ChiefIntroStore: Sendable {
    private let defaults: UserDefaults

    /// - Parameter defaults: The defaults the flags live in. The app passes `.standard`; tests pass a suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether this install has not had its welcome yet (it shows on the only Chief's empty conversation).
    public var welcomePending: Bool {
        let reply: IntroReply = welcomeRule("welcome.intro", IntroInput(state: state, conversation: "", otherChiefs: 0),
                                            fallback: IntroReply(kind: nil, welcomePending: false))
        return reply.welcomePending
    }

    /// The intro `conversation` shows now, or nil when it has nothing to show.
    /// - Parameters:
    ///   - conversation: The empty Chief conversation on screen.
    ///   - otherChiefs: How many other Chiefs the person has (listed, not archived).
    /// - Returns: The welcome for the only Chief (once per install), else the focus question (once per Chief).
    public func intro(for conversation: ConversationID, otherChiefs: Int) -> ChiefIntroKind? {
        let input = IntroInput(state: state, conversation: conversation.rawValue, otherChiefs: otherChiefs)
        let reply: IntroReply = welcomeRule("welcome.intro", input, fallback: IntroReply(kind: nil, welcomePending: false))
        return reply.kind
    }

    /// Records that `kind` showed on `conversation`, so it never shows there again.
    /// - Parameters:
    ///   - kind: The intro that showed.
    ///   - conversation: The Chief conversation it showed on.
    public func markShown(_ kind: ChiefIntroKind, for conversation: ConversationID) {
        let input = MarkInput(state: state, kind: kind, conversation: conversation.rawValue)
        guard let write = welcomeRule("welcome.markShown", input, fallback: MarkReply(write: nil)).write else { return }
        switch write.value {
        case .shown(let shown): defaults.set(shown, forKey: write.key)
        case .asked(let asked): defaults.set(asked, forKey: write.key)
        }
    }

    /// What the defaults hold: whether the welcome showed, and the conversations that asked for their focus.
    private var state: IntroState {
        IntroState(shown: defaults.bool(forKey: IntroState.shownKey), asked: defaults.stringArray(forKey: IntroState.askedKey) ?? [])
    }
}

// The intro ops' wire shapes (cmux-home-rules `welcome/intro.rs`).
private nonisolated struct IntroState: Encodable {
    /// The keys the state is read from (the ops' replies name the key they write).
    static let shownKey = "home.firstRun.chiefIntroShown"
    static let askedKey = "home.firstRun.chiefIntroAsked"
    var shown: Bool
    var asked: [String]
}

private nonisolated struct IntroInput: Encodable {
    var state: IntroState
    var conversation: String
    var otherChiefs: Int
}

private nonisolated struct IntroReply: Decodable {
    var kind: ChiefIntroKind?
    var welcomePending: Bool
}

private nonisolated struct MarkInput: Encodable {
    var state: IntroState
    var kind: ChiefIntroKind
    var conversation: String
}

private nonisolated struct MarkReply: Decodable {
    var write: Write?

    nonisolated struct Write: Decodable {
        var key: String
        var value: Value

        nonisolated enum Value: Decodable {
            case shown(Bool)
            case asked([String])

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let shown = try? container.decode(Bool.self) { self = .shown(shown) } else { self = .asked(try container.decode([String].self)) }
            }
        }
    }
}
