public import Foundation

/// What a page right-click hit: a link, an image or other media, a selection, an editable field.
public struct BrowserContextMenuTarget: Hashable, Sendable {
    /// The link's address.
    public var linkURL: URL?
    /// The media element's address (an image's source, a video's).
    public var sourceURL: URL?
    /// The right-clicked image's address; `nil` for other media.
    public var imageURL: URL?
    /// The page's address.
    public var pageURL: URL?
    /// The selected text; empty when nothing is selected.
    public var selection: String
    /// Whether the click was in an editable field.
    public var isEditable: Bool

    /// Creates a target.
    /// - Parameters:
    ///   - linkURL: The link's address.
    ///   - sourceURL: The media element's address.
    ///   - imageURL: The image's address.
    ///   - pageURL: The page's address.
    ///   - selection: The selected text.
    ///   - isEditable: Whether the click was in an editable field.
    public init(
        linkURL: URL? = nil,
        sourceURL: URL? = nil,
        imageURL: URL? = nil,
        pageURL: URL? = nil,
        selection: String = "",
        isEditable: Bool = false
    ) {
        self.linkURL = linkURL
        self.sourceURL = sourceURL
        self.imageURL = imageURL
        self.pageURL = pageURL
        self.selection = selection
        self.isEditable = isEditable
    }

    /// Decodes Chromium's context menu params as the CEF shim reports them
    /// (`{link_url, source_url, page_url, selection, editable, media_type}`).
    /// - Parameter json: The params JSON object. Malformed input gives an empty target.
    public init(chromiumParamsJSON json: String) {
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            self.init()
            return
        }
        let source = Self.url(wire.source_url)
        self.init(
            linkURL: Self.url(wire.link_url),
            sourceURL: source,
            // CEF's CM_MEDIATYPE_IMAGE.
            imageURL: wire.media_type == 1 ? source : nil,
            pageURL: Self.url(wire.page_url),
            selection: wire.selection ?? "",
            isEditable: wire.editable ?? false
        )
    }

    private static func url(_ text: String?) -> URL? {
        guard let text, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    private struct Wire: Decodable {
        var link_url: String?
        var source_url: String?
        var page_url: String?
        var selection: String?
        var editable: Bool?
        var media_type: Int?
    }
}
