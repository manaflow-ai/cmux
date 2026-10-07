import CmuxMobileWire

/// The page as its owner reports it (`rb.page`).
public struct RbPage: Hashable, Sendable {
    public var url: String
    public var title: String
    public var loading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool

    public init(url: String, title: String, loading: Bool = false, canGoBack: Bool = false, canGoForward: Bool = false) {
        self.url = url
        self.title = title
        self.loading = loading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    var fields: [String: JSONValue] {
        ["url": .string(url), "title": .string(title), "loading": .bool(loading), "can_go_back": .bool(canGoBack),
         "can_go_forward": .bool(canGoForward)]
    }

    init(reader r: RbJSONReader) throws(RdWireError) {
        url = try r.string("url")
        title = try r.string("title")
        loading = try r.bool("loading")
        canGoBack = try r.bool("can_go_back")
        canGoForward = try r.bool("can_go_forward")
    }
}
