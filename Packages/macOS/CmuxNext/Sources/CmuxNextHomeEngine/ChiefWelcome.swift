public import CmuxNextDaemon
public import Foundation

/// Chief's first messages on a fresh install: Chief greets the person, says what it can do, then
/// offers a background, each as its own iMessage bubble after its own typing dots (user, 2026-10-30;
/// "more spaced out, better animation timings", 2026-10-31). The three bubbles are one run, as in
/// Messages: 3 pt apart, and only the last has the tail (user, 2026-11-04).
///
/// The messages are stored as real messages from Chief in the Chief conversation, through the
/// owner's `conversation-import` (which keeps an author other than the person), so the Home
/// transcript draws them with its own iMessage bubbles and motion. Each message has a fixed client
/// id, and the owner skips a message whose author and client id it already holds, so a relaunch, a
/// second window or a retry never stores a second copy.
///
/// The pacing follows Messages: in the lab's lossless Messages recording (`springs.json`,
/// `transcript.typing` at 8.970 s, `transcript.receive` at 10.567 s) the typing bubble shows 1.6 s
/// before a short text lands, and the transcript itself draws the dots' entry (0.27 s scale, 0.35 s
/// fade), their exit (0.27 s) and the bubble's arrival (0.30 s). ``beats`` gives each message a quiet
/// pause (no dots: the window settles, or the person reads the bubble above) and a typing time that
/// grows with the text, so three short bubbles arrive one by one instead of two long ones at once.
///
/// ```swift
/// let welcome = ChiefWelcome(conversation: id, owner: owner, showsTyping: Motion.home.animatesLoops)
/// try await welcome.play { pause in await deadline(pause) }
/// ```
public nonisolated struct ChiefWelcome: Sendable {
    /// One message of the welcome and the time before it.
    public struct Beat: Sendable, Equatable {
        /// The message's fixed client id (the owner's duplicate check).
        public let clientID: String
        /// The message's text.
        public let text: String
        /// The pause before Chief starts typing, with no dots.
        public let quiet: Duration
        /// How long Chief's dots show before the message lands.
        public let typing: Duration
    }

    /// The conversation the welcome goes to: the person's only Chief's.
    public let conversation: String
    /// The Chief participant that writes it.
    public let author: String
    /// Whether Chief types before each message; false sends all of them at once.
    public let showsTyping: Bool
    private let owner: any ChiefWelcomeOwner
    private let text: String

    /// - Parameters:
    ///   - conversation: The Chief conversation's id.
    ///   - author: The Chief participant's id (the local Chief's `agent_mux` by default).
    ///   - owner: The conversation owner the dots and the messages go through.
    ///   - showsTyping: Whether Chief types first (`Motion.home.animatesLoops`). False (Reduce
    ///     Motion, or Home animation off): no dots and no pauses, the messages show at once.
    ///   - text: What Chief can do, with the person's current shortcuts; nil uses the introductory text.
    public init(conversation: String, author: String = DaemonHomeSource.chief.id, owner: any ChiefWelcomeOwner,
                showsTyping: Bool, text: String? = nil) {
        self.conversation = conversation
        self.author = author
        self.owner = owner
        self.showsTyping = showsTyping
        self.text = text ?? HomeStrings.chiefWelcomeAbout
    }

    /// The welcome's messages in order, each with its quiet pause and typing time (`welcome.beats`).
    /// - Parameter about: What Chief can do, with the person's shortcuts.
    /// - Returns: The greeting, `about`, then the background offer.
    static func beats(about: String) -> [Beat] {
        let reply: BeatsReply = welcomeRule("welcome.beats", Texts(about: about), fallback: BeatsReply(beats: []))
        return reply.beats.map(\.beat)
    }

    /// The import that stores `beats`, dated `now` (`welcome.importRequest`).
    /// - Parameters:
    ///   - beats: The messages to store.
    ///   - now: The messages' time (the owner refuses a time in the future).
    /// - Returns: One request with the messages in order.
    public func request(_ beats: [Beat], now: Date) -> ConversationImportRequest {
        let input = ImportInput(conversation: conversation, author: author, beats: beats.map(WireBeat.init), now: now.timeIntervalSince1970)
        let reply: ImportReply = welcomeRule("welcome.importRequest", input,
                                             fallback: ImportReply(request: .init(conversation: conversation, messages: [])))
        return ConversationImportRequest(conversation: reply.request.conversation, messages: reply.request.messages.map {
            ConversationImportedMessage(id: $0.id, clientMsgID: $0.clientMsgID, author: $0.author, parts: $0.parts, createdAt: $0.createdAt)
        })
    }

    /// Plays the welcome: for each beat, its quiet, Chief's dots for its typing time, then its message.
    /// Without typing, all messages land in one import, at once (`welcome.playSteps`).
    /// - Parameters:
    ///   - now: The messages' clock (each is dated when it lands).
    ///   - pause: Waits out a pause (the host's one-shot deadline; tests record it).
    /// - Throws: The owner's import error; the dots are gone and the later messages are not sent.
    public func play(now: @Sendable () -> Date = { Date() }, pause: @Sendable (Duration) async -> Void) async throws {
        let plan: PlayReply = welcomeRule("welcome.playSteps", PlayInput(texts: Texts(about: text), showsTyping: showsTyping),
                                          fallback: PlayReply(beats: [], steps: []))
        let beats = plan.beats.map(\.beat)
        for step in plan.steps {
            switch step {
            case .pause(let ms): await pause(.milliseconds(ms))
            case .typing(let on): await owner.showChiefTyping(on)
            case .importBeats(let indexes):
                do {
                    try await owner.importWelcome(request(indexes.filter(beats.indices.contains).map { beats[$0] }, now: now()))
                } catch {
                    await owner.showChiefTyping(false)
                    throw error
                }
            }
        }
    }
}

// The welcome ops' wire shapes (cmux-home-rules `welcome/script.rs`).
private nonisolated struct Texts: Encodable {
    var hello = HomeStrings.chiefWelcomeHello
    var about: String
    var backgroundFormat = HomeStrings.chiefWelcomeBackgroundFormat
}

private nonisolated struct WireBeat: Codable {
    var clientID: String
    var text: String
    var quietMs: Int64
    var typingMs: Int64

    init(_ beat: ChiefWelcome.Beat) {
        clientID = beat.clientID
        text = beat.text
        quietMs = Self.milliseconds(beat.quiet)
        typingMs = Self.milliseconds(beat.typing)
    }

    var beat: ChiefWelcome.Beat {
        ChiefWelcome.Beat(clientID: clientID, text: text, quiet: .milliseconds(quietMs), typing: .milliseconds(typingMs))
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}

private nonisolated struct BeatsReply: Decodable {
    var beats: [WireBeat]
}

private nonisolated struct PlayInput: Encodable {
    var texts: Texts
    var showsTyping: Bool

    func encode(to encoder: any Encoder) throws {
        try texts.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showsTyping, forKey: .showsTyping)
    }

    private enum CodingKeys: String, CodingKey { case showsTyping }
}

private nonisolated struct PlayReply: Decodable {
    var beats: [WireBeat]
    var steps: [Step]

    nonisolated enum Step: Decodable {
        case pause(Int64)
        case typing(Bool)
        case importBeats([Int])

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "wait": self = .pause(try container.decode(Int64.self, forKey: .ms))
            case "typing": self = .typing(try container.decode(Bool.self, forKey: .on))
            case "import": self = .importBeats(try container.decode([Int].self, forKey: .beats))
            case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown step \(kind)")
            }
        }

        private enum Keys: String, CodingKey { case kind, ms, on, beats }
    }
}

private nonisolated struct ImportInput: Encodable {
    var conversation: String
    var author: String
    var beats: [WireBeat]
    var now: Double
}

private nonisolated struct ImportReply: Decodable {
    var request: Request

    nonisolated struct Request: Decodable {
        var conversation: String
        var messages: [Message]
    }

    nonisolated struct Message: Decodable {
        var id: String?
        var clientMsgID: String
        var author: String
        var parts: [JSONValue]
        var createdAt: String

        private enum CodingKeys: String, CodingKey {
            case id, author, parts
            case clientMsgID = "client_msg_id"
            case createdAt = "created_at"
        }
    }
}
