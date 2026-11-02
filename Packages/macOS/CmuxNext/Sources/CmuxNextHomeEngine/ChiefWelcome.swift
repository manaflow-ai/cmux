public import CmuxNextDaemon
public import Foundation

/// Chief's first messages on a fresh install: Chief greets the person, says what it can do, then
/// offers a background, each as its own iMessage bubble after its own typing dots (user, 2026-10-30;
/// "more spaced out, better animation timings", 2026-10-31).
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

    /// The client id of the greeting.
    public static let helloClientID = "chief-welcome-hello-v2"
    /// The client id of what Chief can do.
    public static let aboutClientID = "chief-welcome-about-v2"
    /// The client id of the background offer.
    public static let backgroundClientID = "chief-welcome-background-v1"
    /// The link in the background offer: it opens the background picker (`appearance.changeBackground`).
    public static let backgroundLink = "cmux://settings/background"
    /// The quiet before the first dots: Home's window and transcript are on screen and still, so the
    /// dots visibly grow in rather than being there on the first frame.
    public static let leadIn: Duration = .milliseconds(600)

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
        self.text = text ?? Self.aboutText
    }

    /// The greeting: "Welcome to cmux! 👋 I'm Chief."
    public static var helloText: String { HomeStrings.chiefWelcomeHello }

    /// What Chief can do, and that the person can just ask.
    public static var aboutText: String { HomeStrings.chiefWelcomeAbout }

    /// The background offer's text, with its picker link.
    public static var backgroundText: String { HomeStrings.chiefWelcomeBackground(link: backgroundLink) }

    /// The welcome's messages in order, each with its quiet pause and typing time.
    public static var beats: [Beat] {
        makeBeats(about: aboutText)
    }

    private static func makeBeats(about: String) -> [Beat] {
        let texts = [(helloClientID, helloText), (aboutClientID, about), (backgroundClientID, backgroundText)]
        var above: String?
        return texts.map { key, text in
            defer { above = text }
            return Beat(clientID: key, text: text, quiet: above.map(readingPause(after:)) ?? leadIn, typing: typingTime(for: text))
        }
    }

    /// How long Chief types `text`: 1.2 s for a greeting (Messages' short reply shows its dots 1.6 s; a
    /// prepared greeting is quicker), 4 ms more per character, at most 2 s so the welcome never drags.
    /// - Parameter text: The message's text.
    /// - Returns: The dots' time on screen.
    public static func typingTime(for text: String) -> Duration {
        .milliseconds(min(2000, max(1200, 1000 + 4 * text.count)))
    }

    /// How long the person reads `text` before Chief types again: 0.6 s to 1 s, longer for a longer
    /// bubble, and always past the bubble's 0.3 s arrival and the dots' 0.27 s exit.
    /// - Parameter text: The message that just landed.
    /// - Returns: The quiet before the next dots.
    public static func readingPause(after text: String) -> Duration {
        .milliseconds(min(1000, max(600, 400 + 3 * text.count)))
    }

    /// The import that stores `beats`, dated `now`.
    /// - Parameters:
    ///   - beats: The messages to store.
    ///   - now: The messages' time (the owner refuses a time in the future).
    /// - Returns: One request with the messages in order.
    public func request(_ beats: [Beat], now: Date) -> ConversationImportRequest {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let time = formatter.string(from: now)
        return ConversationImportRequest(conversation: conversation, messages: beats.map { beat in
            ConversationImportedMessage(id: nil, clientMsgID: beat.clientID, author: author,
                                        parts: [.object(["type": .string("text"), "text": .string(beat.text)])], createdAt: time)
        })
    }

    /// Plays the welcome: for each beat, its quiet, Chief's dots for its typing time, then its message.
    /// Without typing, all messages land in one import, at once.
    /// - Parameters:
    ///   - now: The messages' clock (each is dated when it lands).
    ///   - wait: Waits out a pause (the host's one-shot deadline; tests record it).
    /// - Throws: The owner's import error; the dots are gone and the later messages are not sent.
    public func play(now: @Sendable () -> Date = { Date() }, wait: @Sendable (Duration) async -> Void) async throws {
        let beats = Self.makeBeats(about: text)
        guard showsTyping else {
            try await send(beats, now: now())
            return
        }
        for beat in beats {
            await wait(beat.quiet)
            await owner.showChiefTyping(true)
            await wait(beat.typing)
            try await send([beat], now: now())
        }
    }

    /// Stores `beats`, then takes the dots away (also when the import fails).
    private func send(_ beats: [Beat], now: Date) async throws {
        do {
            try await owner.importWelcome(request(beats, now: now))
        } catch {
            await owner.showChiefTyping(false)
            throw error
        }
        await owner.showChiefTyping(false)
    }
}
