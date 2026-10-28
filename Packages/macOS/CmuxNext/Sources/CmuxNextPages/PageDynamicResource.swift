public import Foundation

/// One generated response body for a page (a patch, a local image): its bytes and, when known,
/// its MIME type. A nil or malformed type falls back to the static rule (the last path
/// component's extension, else `application/octet-stream`).
///
/// A media file answers in byte ranges (``status`` 206 with its ``contentRange``, 416 past the end,
/// and ``acceptsRanges``). A document the page frames in a sandbox (the agent page's render frame)
/// carries its own ``sandboxedPolicy``.
public nonisolated struct PageResource: Sendable, Equatable {
    public let data: Data
    public let mimeType: String?
    /// 200 for the whole body, 206 for the byte range in ``contentRange``, 416 for a range past the end.
    public let status: Int
    /// The `Content-Range` of a 206 or 416 answer (`bytes 0-99/1000`, `bytes */1000`).
    public let contentRange: String?
    /// Sends `Accept-Ranges: bytes`, so a media player asks for the ranges it plays.
    public let acceptsRanges: Bool
    /// The Content Security Policy of a document the page frames: the WebKit scheme handler serves
    /// it as `sandbox allow-scripts; <policy>` instead of the page's policy, so the document always
    /// runs with an opaque origin and cannot reach the page. Chromium's page resources carry only
    /// the page's own policy, so there such a resource is a 404.
    public let sandboxedPolicy: String?

    public init(data: Data, mimeType: String? = nil, status: Int = 200, contentRange: String? = nil,
                acceptsRanges: Bool = false, sandboxedPolicy: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.status = status
        self.contentRange = contentRange
        self.acceptsRanges = acceptsRanges
        self.sandboxedPolicy = sandboxedPolicy
    }
}

/// A request for a generated resource under one of the page's dynamic prefixes:
/// `cmux-page://cmux.diff/__patch/<token>/a.patch` is prefix `__patch`, path `[<token>, a.patch]`.
/// The path is already checked: no `.` or `..` components and no empty components.
public nonisolated struct PageResourceRequest: Sendable, Equatable {
    public let prefix: String
    public let path: [String]
    public let url: URL
    /// The request's HTTP `Range` header (`bytes=0-1`, which a WebKit media player sends); nil
    /// without one, and always in Chromium, whose page resource requests carry no headers.
    public let range: String?

    public init(prefix: String, path: [String], url: URL, range: String? = nil) {
        self.prefix = prefix
        self.path = path
        self.url = url
        self.range = range
    }
}

/// Serves a page's generated resources (diff-host.md decision (c): patches at
/// `cmux-page://cmux.diff/__patch/<token>/...`). The scheme handler asks it first for every path
/// whose first component is one of the descriptor's ``PageDescriptor/dynamicPrefixes``; nil is a
/// 404 and the static files are never consulted for that prefix. The page instance owns it (the
/// App's provider, with its session tokens), so one page's tokens never answer another page.
public protocol PageDynamicResourceSource: AnyObject {
    func resource(for request: PageResourceRequest) async -> PageResource?
}
