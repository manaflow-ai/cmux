public import CmuxNextDaemon
public import Foundation

/// Chief's first message on a fresh install: Chief types for a moment, then welcomes the person
/// to cmux and offers a background image (user, 2026-10-30).
///
/// The welcome is stored as real messages from Chief in the Chief conversation, through the
/// owner's `conversation-import` (which keeps an author other than the person), so the Home
/// transcript draws it with its own iMessage bubbles. Each message has a fixed client id, and the
/// owner skips a message whose author and client id it already holds, so a relaunch, a second
/// window or a retry never stores a second copy.
///
/// The host runs it in two steps around one deadline:
///
/// ```swift
/// let welcome = ChiefWelcome(conversation: id, owner: owner, showsTyping: Motion.home.animatesLoops)
/// if let pause = await welcome.start() {
///     timer.schedule(after: pause) { try? await welcome.deliver() }
/// } else {
///     try await welcome.deliver()
/// }
/// ```
public nonisolated struct ChiefWelcome: Sendable {
    /// The client id of the welcome message.
    public static let welcomeClientID = "chief-welcome-v1"
    /// The client id of the background offer that follows it.
    public static let backgroundClientID = "chief-welcome-background-v1"
    /// How long Chief's typing dots show before the welcome arrives.
    public static let typingPause: Duration = .milliseconds(1500)
    /// The link in the background offer: it opens the background picker (`appearance.changeBackground`).
    public static let backgroundLink = "cmux://settings/background"

    /// The conversation the welcome goes to: the person's only Chief's.
    public let conversation: String
    /// The Chief participant that writes it.
    public let author: String
    private let owner: any ChiefWelcomeOwner
    private let showsTyping: Bool

    /// - Parameters:
    ///   - conversation: The Chief conversation's id.
    ///   - author: The Chief participant's id (the local Chief's `agent_mux` by default).
    ///   - owner: The conversation owner the dots and the messages go through.
    ///   - showsTyping: Whether Chief types first (`Motion.home.animatesLoops`). False (Reduce
    ///     Motion, or Home animation off): no dots and no pause, the welcome shows at once.
    public init(conversation: String, author: String = DaemonHomeSource.chief.id, owner: any ChiefWelcomeOwner,
                showsTyping: Bool) {
        self.conversation = conversation
        self.author = author
        self.owner = owner
        self.showsTyping = showsTyping
    }

    /// The welcome's text: who Chief is and what it can do.
    public static var welcomeText: String { HomeStrings.chiefWelcome }

    /// The background offer's text, with its picker link.
    public static var backgroundText: String { HomeStrings.chiefWelcomeBackground(link: backgroundLink) }

    /// The import that stores both messages, dated `now`.
    /// - Parameter now: The messages' time (the owner refuses a time in the future).
    /// - Returns: One request with the welcome, then the background offer.
    public func request(now: Date) -> ConversationImportRequest {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let time = formatter.string(from: now)
        let message = { (key: String, text: String) in
            ConversationImportedMessage(id: nil, clientMsgID: key, author: author,
                                        parts: [.object(["type": .string("text"), "text": .string(text)])], createdAt: time)
        }
        return ConversationImportRequest(conversation: conversation, messages: [
            message(Self.welcomeClientID, Self.welcomeText),
            message(Self.backgroundClientID, Self.backgroundText),
        ])
    }

    /// Starts the welcome: Chief's dots show.
    /// - Returns: How long the dots show before ``deliver(now:)``; nil when Chief does not type
    ///   first (then deliver at once).
    public func start() async -> Duration? {
        guard showsTyping else { return nil }
        await owner.showChiefTyping(true)
        return Self.typingPause
    }

    /// Stores the messages, then takes the dots away (also when the import fails).
    /// - Parameter now: The messages' time.
    /// - Throws: The owner's import error; then nothing was stored.
    public func deliver(now: Date = Date()) async throws {
        do {
            try await owner.importWelcome(request(now: now))
        } catch {
            await owner.showChiefTyping(false)
            throw error
        }
        await owner.showChiefTyping(false)
    }

    /// The welcome will not be delivered (its view went away first): the dots go away.
    public func abandon() async {
        await owner.showChiefTyping(false)
    }
}
