import Foundation

/// The live Feed saved on the phone, so a relaunch shows the events it had
/// (the Mac's watch only reports what happens next). Keeps finished turns and
/// failures with what the person did to them (read, done, replies). Open asks
/// are not kept: the Mac reports those again on every connection, and a
/// saved one could already be answered.
public struct FeedArchive: Sendable {
    public let url: URL
    /// The most recent items kept.
    public static let limit = 200

    public init(url: URL) {
        self.url = url
    }

    /// The archive for an account in Application Support.
    public static func forAccount(_ accountID: String) -> FeedArchive {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safe = accountID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return FeedArchive(url: base.appending(path: "Feed", directoryHint: .isDirectory).appending(path: "\(safe).json"))
    }

    /// Every read and write of every archive, in order, off the main thread:
    /// encoding 200 events and an atomic protected write took milliseconds on
    /// the main thread at each Feed change, a dropped frame while scrolling.
    static let io = DispatchQueue(label: "dev.cmux.mobile.feed-archive", qos: .utility)

    /// Sign-out: the account's Feed (agent names, places, turn text) leaves
    /// this phone. Waits for writes already queued, so none lands after it.
    public func remove() {
        Self.io.sync { try? FileManager.default.removeItem(at: url) }
    }

    /// Saves `items` on the archive queue (the caller never waits).
    public func saveInBackground(_ items: [FeedItem]) {
        Self.io.async { save(items) }
    }

    public func load() -> [FeedItem] {
        Self.io.sync { read() }
    }

    private func read() -> [FeedItem] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap(\.item)
    }

    public func save(_ items: [FeedItem]) {
        let entries = items.compactMap(Entry.init).sorted { $0.createdAt > $1.createdAt }.prefix(Self.limit)
        guard let data = try? JSONEncoder().encode(Array(entries)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    struct Entry: Codable {
        enum Kind: String, Codable { case response, finished, failed }
        var id: String
        var kind: Kind
        var workspaceID: String
        var tabID: String
        var agentName: String
        var harness: String
        var workspaceTitle: String
        /// The tab's name (nil in archives before it existed).
        var tabTitle: String?
        var markdown: String
        var quote: String?
        var quoteFromAgent: Bool?
        var createdAt: Date
        var isRead: Bool
        var isDone: Bool
        var resolution: String?
        var replies: [String]
        /// A terminal agent's event (nil in archives before it existed).
        var opensTerminal: Bool?
        /// The Mac that sent it (nil in archives before it existed).
        var macID: String?

        init?(_ item: FeedItem) {
            switch item.kind {
            case .response: kind = .response
            case .finished: kind = .finished
            case .failed: kind = .failed
            case .question, .permission, .needsInput: return nil
            }
            id = item.id
            workspaceID = item.workspaceID
            tabID = item.tabID
            agentName = item.agentName
            harness = item.harness
            workspaceTitle = item.workspaceTitle
            tabTitle = item.tabTitle.isEmpty ? nil : item.tabTitle
            markdown = item.markdown
            quote = item.quote?.text
            quoteFromAgent = item.quote?.author == .agent ? true : nil
            createdAt = item.createdAt
            isRead = item.isRead
            isDone = item.isDone
            resolution = item.resolution
            replies = item.replies
            opensTerminal = item.opensTerminal ? true : nil
            macID = item.macID
        }

        var item: FeedItem? {
            let kind: FeedItem.Kind = switch self.kind {
            case .response: .response
            case .finished: .finished
            case .failed: .failed
            }
            var item = FeedItem(
                id: id, kind: kind, workspaceID: workspaceID, tabID: tabID, agentName: agentName, harness: harness,
                workspaceTitle: workspaceTitle, markdown: markdown,
                quote: quote.map { FeedItem.Quote($0, author: quoteFromAgent == true ? .agent : .you) }, createdAt: createdAt
            )
            item.isRead = isRead
            item.isDone = isDone
            item.resolution = resolution
            item.replies = replies
            item.opensTerminal = opensTerminal == true
            item.macID = macID
            item.tabTitle = tabTitle ?? ""
            return item
        }
    }
}
