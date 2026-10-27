import Foundation

/// A card an agent (the Chief) posts in a message: the `card` conversation
/// part (https://github.com/manaflow-ai/cmux/issues/25830). Clients draw it
/// in place of text; ``fallbackText`` is what a reader without cards shows.
public enum ConversationCard: Sendable, Hashable {
    /// The live browser or computer-use card: the step the agent is on and
    /// its latest screenshot. The agent edits the one message as it goes.
    case browser(ConversationBrowserCard)
    /// Secure Store: the agent needs a sign-in for a site.
    case signIn(ConversationSignInCard)
    /// Suggested next steps under the reply's text; a tap sends one.
    case nextSteps(ConversationNextSteps)

    /// The line a client without cards (a transcript, a preview) shows.
    public var fallbackText: String {
        switch self {
        case let .browser(card): return card.fallbackText
        case let .signIn(card): return card.fallbackText
        case let .nextSteps(steps): return steps.fallbackText
        }
    }

    /// Drops C0/C1 controls and trims: what a card shows of agent text.
    static func cleaned(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isControlLike }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An http or https URL, as link previews accept them.
    static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

private extension Unicode.Scalar.Properties {
    var isControlLike: Bool { generalCategory == .control }
}

public struct ConversationBrowserCard: Sendable, Hashable {
    public enum Surface: String, Sendable, Hashable {
        case browser
        case computer
    }

    /// What "Open browser" opens.
    public enum Target: Sendable, Hashable {
        /// The browser column right of the Home chat on the Mac running the Chief.
        case browserRight
        /// That cmux Cloud machine's desktop.
        case machine(String)

        /// `browser:right` or `machine:<id>` (id `[A-Za-z0-9_-]{1,128}`).
        public init?(wire: String?) {
            guard let wire else { return nil }
            if wire == "browser:right" {
                self = .browserRight
                return
            }
            guard wire.hasPrefix("machine:") else { return nil }
            let id = String(wire.dropFirst("machine:".count))
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
            guard (1...128).contains(id.count), id.allSatisfy(allowed.contains) else { return nil }
            self = .machine(id)
        }

        public var wire: String {
            switch self {
            case .browserRight: return "browser:right"
            case let .machine(id): return "machine:\(id)"
            }
        }
    }

    public var surface: Surface
    /// The current step, 1...200 characters.
    public var step: String
    /// The agent still drives it; false once the turn ended.
    public var live: Bool
    public var target: Target?
    public var url: URL?
    /// The latest screenshot, an attachment of this conversation (its bytes
    /// in `localData` once read, as for an `attachment` part).
    public var image: ConversationAttachment?

    public static let maxStepLength = 200

    /// Nil when `step` is empty after cleaning; a longer step is cut.
    public init?(surface: Surface, step: String, live: Bool = false, target: Target? = nil,
                 url: URL? = nil, image: ConversationAttachment? = nil) {
        let cleaned = ConversationCard.cleaned(step)
        guard !cleaned.isEmpty else { return nil }
        self.surface = surface
        self.step = String(cleaned.prefix(Self.maxStepLength))
        self.live = live
        self.target = target
        self.url = url.flatMap { ConversationCard.webURL($0.absoluteString) }
        self.image = image
    }

    /// "Browser" or "Computer".
    public var title: String {
        switch surface {
        case .browser: return String(localized: "conversation.card.browser.title", defaultValue: "Browser", bundle: .module)
        case .computer: return String(localized: "conversation.card.computer.title", defaultValue: "Computer", bundle: .module)
        }
    }

    /// "Browser: <step>".
    public var fallbackText: String {
        String(format: String(localized: "conversation.card.browser.fallback", defaultValue: "%1$@: %2$@", bundle: .module), title, step)
    }
}

public struct ConversationSignInCard: Sendable, Hashable {
    /// Lowercase DNS name with at least one dot.
    public var site: String
    /// The login page, if the agent named one.
    public var url: URL?

    /// Nil unless `site` is a lowercase DNS name (`[a-z0-9.-]`, 1...253, a dot).
    public init?(site: String, url: URL? = nil) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard (1...253).contains(site.count), site.contains("."), site.allSatisfy(allowed.contains),
              !site.hasPrefix("."), !site.hasSuffix("."), !site.contains("..") else { return nil }
        self.site = site
        self.url = url.flatMap { ConversationCard.webURL($0.absoluteString) }
    }

    /// "Sign in to <site>".
    public var subtitle: String {
        String(format: String(localized: "conversation.card.signIn.subtitle", defaultValue: "Sign in to %@", bundle: .module), site)
    }

    /// "Secure Store".
    public static var title: String {
        String(localized: "conversation.card.signIn.title", defaultValue: "Secure Store", bundle: .module)
    }

    /// "Secure Store: sign in to <site>".
    public var fallbackText: String {
        String(format: String(localized: "conversation.card.signIn.fallback", defaultValue: "Secure Store: sign in to %@", bundle: .module), site)
    }

    /// What the person sends once the sign-in is saved in the Mac's Secure
    /// Store; it wakes the Chief, which fills the login on the Mac.
    public var addedMessage: String {
        String(format: String(localized: "conversation.card.signIn.addedMessage", defaultValue: "I added my sign-in for %@ to the Secure Store.", bundle: .module), site)
    }

    /// What the person sends from a device that cannot save to the Mac's
    /// Secure Store (the iPhone): they will add it on the Mac.
    public var addOnMacMessage: String {
        String(format: String(localized: "conversation.card.signIn.addOnMacMessage", defaultValue: "I'll add my sign-in for %@ on my Mac.", bundle: .module), site)
    }

    /// The sign-in reads as added when a later message of mine says so
    /// (``addedMessage``, in this language or in English).
    public func isAdded(after index: Int, in messages: [ConversationMessage], meID: String?) -> Bool {
        let english = "I added my sign-in for \(site) to the Secure Store."
        let texts: Set<String> = [addedMessage, english]
        return !ConversationCard.laterTexts(after: index, in: messages, meID: meID, matching: texts).isEmpty
    }
}

public struct ConversationNextSteps: Sendable, Hashable {
    /// 1...3 distinct choices, each 1...120 characters.
    public var choices: [String]

    public static let maxChoices = 3
    public static let maxChoiceLength = 120

    /// Cleans, drops empty and repeated choices, keeps the first three and
    /// cuts long ones. Nil when no choice is left.
    public init?(choices: [String]) {
        var kept: [String] = []
        for choice in choices {
            let cleaned = String(ConversationCard.cleaned(choice).prefix(Self.maxChoiceLength))
            guard !cleaned.isEmpty, !kept.contains(cleaned) else { continue }
            kept.append(cleaned)
            if kept.count == Self.maxChoices { break }
        }
        guard !kept.isEmpty else { return nil }
        self.choices = kept
    }

    /// Each choice on its own line, prefixed "→ ".
    public var fallbackText: String {
        choices.map { "→ \($0)" }.joined(separator: "\n")
    }

    /// The choices a later message of mine sent, word for word: those chips
    /// show as chosen.
    public func chosen(after index: Int, in messages: [ConversationMessage], meID: String?) -> Set<String> {
        ConversationCard.laterTexts(after: index, in: messages, meID: meID, matching: Set(choices))
    }
}

extension ConversationCard {
    /// Of `texts`, those that one of my messages after `index` says exactly
    /// (surrounding whitespace aside; unsent messages do not count).
    static func laterTexts(after index: Int, in messages: [ConversationMessage], meID: String?, matching texts: Set<String>) -> Set<String> {
        guard let meID, !texts.isEmpty, index + 1 < messages.count else { return [] }
        var found: Set<String> = []
        for message in messages[(max(0, index + 1))...] where message.senderID == meID && !message.isUnsent {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if texts.contains(text) { found.insert(text) }
            if found.count == texts.count { break }
        }
        return found
    }
}

extension ConversationMessage {
    /// The browser or computer card, if the message carries one.
    public var browserCard: ConversationBrowserCard? {
        for card in cards { if case let .browser(value) = card { return value } }
        return nil
    }

    /// The Secure Store card, if the message carries one.
    public var signInCard: ConversationSignInCard? {
        for card in cards { if case let .signIn(value) = card { return value } }
        return nil
    }

    /// The next-step chips, if the message carries them.
    public var nextSteps: ConversationNextSteps? {
        for card in cards { if case let .nextSteps(value) = card { return value } }
        return nil
    }

    /// Text then each card's fallback line: what a preview or VoiceOver says
    /// for a message whose content is (partly) cards.
    public var textWithCards: String {
        ([text] + cards.map(\.fallbackText)).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
