public import CmuxNextDaemon
public import Foundation

/// The Chief's welcome (#26053): on the first launch on this Mac, the Chief's own conversation
/// gets one message from the Chief with the key shortcuts (⌘P first), a few things to ask it and
/// that it answers anything about cmux, coding agents and browsers. It is written with
/// `conversation-import` under the Chief as author, so no model turn runs and the Chief's own
/// session sees it as its first reply.
///
/// Once per Mac (``postedKey``): only into a Chief conversation with no messages yet; one with
/// history (an upgrade) is marked done without a post. The import's client id makes a retry that
/// raced an earlier post a no-op in the owner.
public nonisolated struct ChiefWelcome {
    /// Set once the welcome was posted, or was found not due (UserDefaults).
    public static let postedKey = "cmux.home.chiefWelcome.posted"
    /// The welcome's client message id: the owner skips a second import of it.
    static let clientMsgID = "chief-welcome-v1"

    /// One shortcut line: the keys as the registry shows them (rebinds included) and the action's title.
    public struct Shortcut: Sendable, Equatable {
        public var keys: String
        public var title: String

        public init(keys: String, title: String) {
            self.keys = keys
            self.title = title
        }
    }

    /// What one look at the Chief conversation does.
    public enum Step: Equatable {
        /// Post the welcome into this conversation.
        case post(String)
        /// Not due (posted before, or the conversation has history): mark done.
        case done
        /// No local Chief conversation yet: look again on a later connection.
        case wait
    }

    /// Where the record lives, and the Chief that writes the welcome (`agent_mux`).
    let defaults: UserDefaults
    let chief: String

    public init(defaults: UserDefaults, chief: String) {
        self.defaults = defaults
        self.chief = chief
    }

    /// Whether the welcome was posted, or found not due, on this Mac.
    public var posted: Bool { defaults.bool(forKey: Self.postedKey) }

    /// `conversation` is the local Chief conversation, nil while it is unknown; `lastSeq` its newest seq.
    public func step(conversation: String?, lastSeq: UInt64) -> Step {
        if posted { return .done }
        guard let conversation else { return .wait }
        return lastSeq == 0 ? .post(conversation) : .done
    }

    /// The welcome's Markdown: ⌘P (`goTo`, nil when unbound) called out on its own, then `shortcuts`.
    public static func text(goTo: String?, shortcuts: [Shortcut]) -> String {
        var blocks = [HomeStrings.chiefWelcomeIntro]
        if let goTo { blocks.append(HomeStrings.chiefWelcomeGoTo(goTo)) }
        if !shortcuts.isEmpty {
            let lines = shortcuts.map { "- `\($0.keys)` \($0.title)" }
            blocks.append(([HomeStrings.chiefWelcomeShortcuts] + lines).joined(separator: "\n"))
        }
        blocks.append(HomeStrings.chiefWelcomeExamplesHeader + "\n" + HomeStrings.chiefWelcomeExamples)
        blocks.append(HomeStrings.chiefWelcomeAsk)
        return blocks.joined(separator: "\n\n")
    }

    /// The import of `text` into `conversation`, authored by `chief`, at `at`.
    public static func request(conversation: String, chief: String, text: String, at: Date) -> ConversationImportRequest {
        let message = ConversationImportedMessage(id: nil, clientMsgID: clientMsgID, author: chief,
                                                  parts: [.object(["type": .string("text"), "text": .string(text)])],
                                                  createdAt: timestamp(at))
        return ConversationImportRequest(conversation: conversation, messages: [message])
    }

    /// Posts the welcome when due and records it in `defaults`; a failed import records nothing, so
    /// the next connection tries again. Returns the step taken.
    @MainActor @discardableResult
    public func run(conversation: String?, lastSeq: UInt64, text: () -> String, at: Date = Date(),
                    send: @MainActor (ConversationImportRequest) async throws -> Void) async -> Step {
        let step = step(conversation: conversation, lastSeq: lastSeq)
        switch step {
        case .wait:
            return .wait
        case .done:
            defaults.set(true, forKey: Self.postedKey)
            return .done
        case let .post(id):
            do {
                try await send(Self.request(conversation: id, chief: chief, text: text(), at: at))
            } catch {
                return .wait
            }
            defaults.set(true, forKey: Self.postedKey)
            return step
        }
    }

    /// The owner's time format (`YYYY-MM-DDTHH:MM:SS.mmmZ`), a millisecond back so it is never in
    /// the owner's future.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date.addingTimeInterval(-0.001))
    }
}
