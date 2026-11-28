public import CmuxHomeCore
public import Foundation

/// The per-turn settings the app supplies: the prompt, where the brain runs
/// and its environment. The owner never builds a prompt itself.
public struct ChiefTurnContext: Sendable, Equatable {
    /// The Chief's system prompt for this turn.
    public var systemPrompt: String
    /// The brain process's working directory.
    public var workingDirectory: URL
    /// Extra environment for the brain process (socket paths, the Chief home).
    public var environment: [String: String]
    /// The engine that answers, recorded in the turn's ``ChiefTurnStats``; nil when unknown.
    public var engine: ChiefTurnEngine?
    /// Text the owner prepends to this turn's user text, nil for none: a
    /// `<memory-update>` block when memory changed since the brain session
    /// started (``ChiefMemoryFreshness``), since the system prompt only
    /// reaches a brain when its session starts.
    public var turnPreamble: String?

    /// Creates a context.
    ///
    /// - Parameters:
    ///   - systemPrompt: The Chief's system prompt.
    ///   - workingDirectory: The process's working directory.
    ///   - environment: Extra process environment; empty by default.
    ///   - engine: The engine that answers, for the turn's stats; nil by default.
    ///   - turnPreamble: Text to prepend to the user text; nil by default.
    public init(systemPrompt: String, workingDirectory: URL, environment: [String: String] = [:],
                engine: ChiefTurnEngine? = nil, turnPreamble: String? = nil) {
        self.systemPrompt = systemPrompt
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.engine = engine
        self.turnPreamble = turnPreamble
    }

    /// `userText` with ``turnPreamble`` before it, separated by a blank line.
    public func userText(_ userText: String) -> String {
        guard let preamble = turnPreamble?.trimmingCharacters(in: .whitespacesAndNewlines), !preamble.isEmpty else {
            return userText
        }
        return preamble + "\n\n" + userText
    }
}

/// What the owner tells a ``ChiefTurnContextProvider`` about the turn it starts.
public struct ChiefTurnContextInput: Sendable, Equatable {
    /// The conversation the turn answers in.
    public var conversation: ConversationID
    /// The Chief that answers (the default Chief or one made with `createChief`).
    public var chief: Participant
    /// The Chief home the owner uses.
    public var home: ChiefHome
    /// The CLI session the turn resumes, if any.
    public var resumeSession: String?

    /// Creates an input.
    ///
    /// - Parameters:
    ///   - conversation: The conversation.
    ///   - chief: The answering Chief.
    ///   - home: The Chief home.
    ///   - resumeSession: The session to resume.
    public init(conversation: ConversationID, chief: Participant, home: ChiefHome, resumeSession: String?) {
        self.conversation = conversation
        self.chief = chief
        self.home = home
        self.resumeSession = resumeSession
    }
}

/// Builds the ``ChiefTurnContext`` of each turn; the app injects it into
/// ``ChiefConversationOwner``.
public typealias ChiefTurnContextProvider = @Sendable (ChiefTurnContextInput) async -> ChiefTurnContext
