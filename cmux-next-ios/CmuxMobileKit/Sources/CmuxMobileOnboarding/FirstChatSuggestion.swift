import Foundation

/// A starter task on the first-run "first agent" page (ChatGPT's and Claude's
/// empty-chat starters): a short title for the card, one line under it, and the
/// message Chief receives when the card is tapped.
public struct FirstChatSuggestion: Equatable, Sendable, Identifiable {
    public let id: String
    /// An SF Symbol name.
    public let symbol: String
    public let title: String
    public let detail: String
    /// What is sent to Chief, written as the person would type it.
    public let prompt: String

    public init(id: String, symbol: String, title: String, detail: String, prompt: String) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.prompt = prompt
    }

    /// The four starters, in the order shown. Each is a real first task for a
    /// coding agent on the person's Mac, phrased so Chief can start it without
    /// a follow-up question (the last one asks one on purpose).
    public static let starters: [FirstChatSuggestion] = [
        FirstChatSuggestion(
            id: "tour", symbol: "map",
            title: "Explain my project",
            detail: "A short tour of the code",
            prompt: "Give me a short tour of the project I have open on my Mac: what it does, how it is laid out, and where to start reading."
        ),
        FirstChatSuggestion(
            id: "test", symbol: "ladybug",
            title: "Fix a failing test",
            detail: "Find one, fix it, show the diff",
            prompt: "Run the tests in my current project, pick one that fails, fix it, and show me the diff."
        ),
        FirstChatSuggestion(
            id: "review", symbol: "checklist",
            title: "Review my changes",
            detail: "Before I commit",
            prompt: "Review the uncommitted changes in my current project and tell me what to fix before I commit."
        ),
        FirstChatSuggestion(
            id: "plan", symbol: "sparkles",
            title: "Plan a feature",
            detail: "Ask me first, then plan",
            prompt: "Help me plan a small feature for my current project. Ask me what I want first, then write the plan."
        ),
    ]

    /// The message a typed task sends: trimmed, nil when nothing is left.
    public static func typedPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What the "first agent" page says about where the task will run.
public struct FirstChatDestination: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A Mac is online: Chief starts the task there now.
        case online(macName: String)
        /// The account has a Mac, but none is online: the task waits in Chief's composer.
        case waiting
        /// The account has never connected a Mac: nothing can run yet. The task waits in
        /// Chief's composer, and the page offers the way to connect one.
        case noMac
    }

    public let kind: Kind

    /// `accountHasMac`: whether the account has any Mac (nil: not known yet, read as
    /// having one, so a slow Mac list never claims there is none).
    public init(onlineMac: String?, accountHasMac: Bool? = nil) {
        if let onlineMac, !onlineMac.isEmpty {
            kind = .online(macName: onlineMac)
        } else if accountHasMac == false {
            kind = .noMac
        } else {
            kind = .waiting
        }
    }

    /// The line under the page's title.
    public var subtitle: String {
        switch kind {
        case .online(let mac): "Chief starts it on \(mac) and tells you when it needs you."
        case .waiting: "Your Mac isn't online yet. Pick a task; it waits in Chief's message field for you to send once your Mac connects."
        case .noMac: "Agents run on your Mac, and none is connected yet. Pick a task now and it waits in Chief's message field; connect your Mac to send it."
        }
    }

    /// The status chip's text above the starters.
    public var status: String {
        switch kind {
        case .online(let mac): mac
        case .waiting: "Waiting for your Mac"
        case .noMac: "No Mac connected"
        }
    }

    public var isOnline: Bool {
        if case .online = kind { return true }
        return false
    }

    /// Whether the page offers "Connect your Mac" (any state but online).
    public var offersConnect: Bool { !isOnline }
}
