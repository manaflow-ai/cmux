public import Foundation

/// One generated response body for a page (a patch, a local image): its bytes and, when known,
/// its MIME type. A nil or malformed type falls back to the static rule (the last path
/// component's extension, else `application/octet-stream`).
public nonisolated struct PageResource: Sendable, Equatable {
    public let data: Data
    public let mimeType: String?

    public init(data: Data, mimeType: String? = nil) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// A request for a generated resource under one of the page's dynamic prefixes:
/// `cmux-page://cmux.diff/__patch/<token>/a.patch` is prefix `__patch`, path `[<token>, a.patch]`.
/// The path is already checked: no `.` or `..` components and no empty components.
public nonisolated struct PageResourceRequest: Sendable, Equatable {
    public let prefix: String
    public let path: [String]
    public let url: URL

    public init(prefix: String, path: [String], url: URL) {
        self.prefix = prefix
        self.path = path
        self.url = url
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
