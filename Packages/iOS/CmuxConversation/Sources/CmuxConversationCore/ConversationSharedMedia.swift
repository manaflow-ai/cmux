import Foundation

/// A photo shared in the conversation, as the details panel lists it.
public struct ConversationSharedPhoto: Sendable, Hashable, Identifiable {
    public var messageID: String
    public var attachment: ConversationAttachment
    public var sentAt: Date

    public var id: String { attachment.id }
}

/// A link shared in the conversation (its rich card's metadata).
public struct ConversationSharedLink: Sendable, Hashable, Identifiable {
    public var messageID: String
    public var preview: ConversationLinkPreview
    public var sentAt: Date

    public var id: String { preview.url.absoluteString }
}

/// What the details panel's Photos and Links sections show: everything
/// shared in the loaded messages, newest first. Unsent (taken back)
/// messages share nothing.
public enum ConversationSharedMedia {
    public static func photos(in messages: [ConversationMessage]) -> [ConversationSharedPhoto] {
        var result: [ConversationSharedPhoto] = []
        for message in messages.reversed() where !message.isUnsent && !message.isScheduled {
            for attachment in message.attachments.reversed() where attachment.kind == .image && (attachment.url != nil || attachment.localData != nil) {
                result.append(ConversationSharedPhoto(messageID: message.id, attachment: attachment, sentAt: message.sentAt))
            }
        }
        return result
    }

    /// One entry per URL (its newest share).
    public static func links(in messages: [ConversationMessage]) -> [ConversationSharedLink] {
        var seen = Set<URL>()
        var result: [ConversationSharedLink] = []
        for message in messages.reversed() where !message.isUnsent && !message.isScheduled {
            guard let preview = message.linkPreview, seen.insert(preview.url).inserted else { continue }
            result.append(ConversationSharedLink(messageID: message.id, preview: preview, sentAt: message.sentAt))
        }
        return result
    }
}

/// The details panel's Photos and Links sections with Messages' "Show
/// More": each section starts with one page of items and grows a page at a
/// time. When the loaded messages run short, it pages older history in
/// through the store (at most `maxPagesPerRequest` pages per press), so a
/// conversation with photos far back still fills the section.
@MainActor
public final class ConversationSharedMediaModel {
    public enum Section: Sendable, Hashable {
        case photos
        case links
    }

    public let store: ConversationStore
    public let photoPage: Int
    public let linkPage: Int
    public static let maxPagesPerRequest = 5
    public private(set) var photoLimit: Int
    public private(set) var linkLimit: Int
    private var pagesLeft = 0
    /// The section whose "Show More" is paging history.
    private var searching: Section = .photos
    private var cachedCount = -1
    private var cachedFirstID: String?
    private var cachedLastID: String?
    private var allPhotos: [ConversationSharedPhoto] = []
    private var allLinks: [ConversationSharedLink] = []

    public init(store: ConversationStore, photoPage: Int, linkPage: Int) {
        self.store = store
        self.photoPage = photoPage
        self.linkPage = linkPage
        photoLimit = photoPage
        linkLimit = linkPage
    }

    private func refreshCache() {
        let messages = store.messages
        // Messages change in place too (an unsend, a loaded card); the cheap
        // key catches growth, and `invalidate()` covers in-place updates.
        guard messages.count != cachedCount || messages.first?.id != cachedFirstID || messages.last?.id != cachedLastID else { return }
        cachedCount = messages.count
        cachedFirstID = messages.first?.id
        cachedLastID = messages.last?.id
        allPhotos = ConversationSharedMedia.photos(in: messages)
        allLinks = ConversationSharedMedia.links(in: messages)
    }

    /// Drops the cache after an in-place message update.
    public func invalidate() {
        cachedCount = -1
    }

    public var photos: [ConversationSharedPhoto] {
        refreshCache()
        return Array(allPhotos.prefix(photoLimit))
    }

    public var links: [ConversationSharedLink] {
        refreshCache()
        return Array(allLinks.prefix(linkLimit))
    }

    private func available(_ section: Section) -> Int {
        refreshCache()
        return section == .photos ? allPhotos.count : allLinks.count
    }

    private func limit(_ section: Section) -> Int {
        section == .photos ? photoLimit : linkLimit
    }

    /// Whether "Show More" applies: more items are loaded, or older history
    /// may still hold some.
    public func hasMore(_ section: Section) -> Bool {
        available(section) > limit(section) || (store.hasLoadedNewest && store.older != .exhausted)
    }

    /// Older history is loading on behalf of "Show More".
    public var isLoadingMore: Bool {
        pagesLeft > 0 && store.older != .idle && store.older != .exhausted
    }

    public func showMore(_ section: Section) {
        switch section {
        case .photos: photoLimit += photoPage
        case .links: linkLimit += linkPage
        }
        searching = section
        pagesLeft = Self.maxPagesPerRequest
        storeDidChange()
    }

    /// Call on every store change: continues a "Show More" history search.
    public func storeDidChange() {
        guard pagesLeft > 0 else { return }
        guard available(searching) < limit(searching) else {
            pagesLeft = 0
            return
        }
        switch store.older {
        case .exhausted:
            pagesLeft = 0
        case .loading, .retrying:
            return
        case .idle:
            guard store.hasLoadedNewest else { return }
            pagesLeft -= 1
            store.loadOlder()
        }
    }
}
