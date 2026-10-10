import Foundation

/// A `link_preview` part (cmux-tui spec/commands.md): a link with the
/// preview its sender fetched; receivers render only from it. `image` is an
/// ordinary image attachment (JPEG or WebP, at most 512 KB) the sender
/// uploaded to the conversation, read back by its hash.
public struct ConversationLinkPreview: Codable, Sendable, Hashable {
    public var url: String
    public var title: String?
    public var site: String?
    public var image: ConversationDerivedImage?

    public init(url: String, title: String? = nil, site: String? = nil, image: ConversationDerivedImage? = nil) {
        self.url = url
        self.title = title
        self.site = site
        self.image = image
    }
}
