public import Foundation

/// One open request of the app's own Feed for the iPhone (manaflow-ai/cmux#33818): a PR held
/// for trial, a sign-in, a consent card. hostd keeps every rule (what is valid, what is new,
/// what was pushed: `cmux-mobile-host` `needs_you.rs`); this is only what the app knows.
public struct MobileHostNeedsYouRequest: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    /// The prompt kind (`review`, `signIn`, `approve`).
    public var kind: String
    /// Who posted it ("GitHub").
    public var source: String
    public var url: URL?
    public var createdAt: Date

    public init(id: String, title: String, body: String, kind: String, source: String, url: URL?, createdAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.source = source
        self.url = url
        self.createdAt = createdAt
    }
}

extension MobileHostLaunch {
    /// The control line with the Feed's whole set of open requests (`needs_you`).
    public static func needsYouLine(_ requests: [MobileHostNeedsYouRequest]) -> Data {
        anyLine([
            "type": "needs_you",
            "items": requests.map { request -> [String: Any] in
                var item: [String: Any] = [
                    "id": request.id, "title": request.title, "body": request.body, "kind": request.kind,
                    "source": request.source, "created_at_ms": Int64(exactly: (request.createdAt.timeIntervalSince1970 * 1000).rounded()) ?? 0,
                ]
                if let url = request.url { item["url"] = url.absoluteString }
                return item
            },
        ])
    }
}
