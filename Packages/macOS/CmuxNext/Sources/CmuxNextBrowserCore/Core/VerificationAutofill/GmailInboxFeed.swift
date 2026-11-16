public import Foundation

/// One read of Gmail's inbox feed (`https://mail.google.com/mail/u/N/feed/atom`): the account it
/// belongs to and its unread inbox entries, parsed in memory
/// (plans/cmux-next/email-verification-autofill/DESIGN.md "Gmail in cmux's browser"). The feed
/// is Google's own document, not page content: its author address is the From address Gmail
/// shows, never a display name. Nothing here is kept after the read.
public nonisolated struct GmailInboxFeed: Sendable, Hashable {
    /// One unread inbox message: subject, snippet, From address, arrival.
    public struct Entry: Sendable, Hashable {
        public let id: String
        public let subject: String
        public let snippet: String
        public let senderAddress: String
        public let receivedAt: Date
    }

    /// The account's address, from the feed title ("Gmail - Inbox for you@example.com"), lowercased.
    public let account: String
    public let entries: [Entry]

    /// Parses a feed document; nil when it is not a Gmail inbox feed (a sign-in page, an error).
    /// - Parameter data: The response body.
    public static func parse(_ data: Data) -> GmailInboxFeed? {
        let reader = AtomReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.isFeed, let account = Self.address(in: reader.feedTitle) else { return nil }
        let entries = reader.entries.compactMap { raw -> Entry? in
            guard let id = raw["id"], !id.isEmpty, let sender = raw["email"], sender.contains("@"),
                  let issued = raw["issued"].flatMap(Self.date) ?? raw["modified"].flatMap(Self.date) else { return nil }
            return Entry(id: id, subject: raw["title"] ?? "", snippet: raw["summary"] ?? "",
                         senderAddress: sender.trimmingCharacters(in: .whitespacesAndNewlines), receivedAt: issued)
        }
        return GmailInboxFeed(account: account, entries: entries)
    }

    /// The first email address in `text`, lowercased.
    static func address(in text: String) -> String? {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return text[range].lowercased()
    }

    private static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }
}

extension GmailInboxFeed.Entry: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "GmailInboxFeed.Entry(id: \(id), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["id": id], displayStyle: .struct) }
}

/// Collects the feed title and each entry's simple fields. XMLParser's delegate must be an
/// NSObject; it lives for one parse.
private nonisolated final class AtomReader: NSObject, XMLParserDelegate {
    var isFeed = false
    var feedTitle = ""
    var entries: [[String: String]] = []
    private var current: [String: String]?
    private var inAuthor = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "feed": isFeed = true
        case "entry": current = [:]
        case "author": inAuthor = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        if name == "author" { inAuthor = false; return }
        if name == "entry" {
            if let current { entries.append(current) }
            current = nil
            return
        }
        guard current != nil else {
            if name == "title", feedTitle.isEmpty { feedTitle = value }
            return
        }
        switch name {
        case "email" where inAuthor: current?["email"] = value
        case "name" where inAuthor: break
        case "title", "summary", "issued", "modified", "id": current?[name] = value
        default: break
        }
    }
}
