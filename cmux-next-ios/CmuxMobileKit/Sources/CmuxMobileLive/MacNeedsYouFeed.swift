import CmuxMobileFeed
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "feed")

/// The Mac app's own Feed requests in the phone's Feed (manaflow-ai/cmux#33818): PRs held for
/// trial, sign-ins and consent cards, which live in the Mac app's Feed, never in acpmux or the
/// daemon's ledger. The Mac's host serves the open set on the `needs-you` service
/// (cmux-mobile-host `needs_you.rs`: `{"items":[...]}` now and on every change) and pushes each
/// request once; here each open request is a pinned Needs you row (`needsInput`) that opens its
/// link, and a request the Mac no longer lists leaves the Feed.
///
/// The channel lives as long as the Mac's link; a host without the service (an older Mac)
/// refuses it and nothing more is asked on that link.
@MainActor
public final class MacNeedsYouFeed {
    /// One open request as the Mac's host serves it.
    public struct Request: Equatable, Sendable {
        public var id: String
        public var title: String
        public var body: String
        public var kind: String
        public var source: String
        public var url: URL?
        public var createdAt: Date

        public init?(json: [String: Any]) {
            guard let id = json["id"] as? String, !id.isEmpty, let title = json["title"] as? String, !title.isEmpty else { return nil }
            self.id = id
            self.title = title
            body = json["body"] as? String ?? ""
            kind = json["kind"] as? String ?? ""
            source = json["source"] as? String ?? ""
            url = (json["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            createdAt = Date(timeIntervalSince1970: TimeInterval((json["created_at_ms"] as? Int64) ?? Int64(json["created_at_ms"] as? Int ?? 0)) / 1000)
        }
    }

    /// The `needs-you` service of the Mac's host.
    public static let service = "needs-you"

    let store: FeedStore
    /// The Feed items this Mac's requests made, by item id.
    private var shown: Set<String> = []

    public init(store: FeedStore) {
        self.store = store
    }

    /// The Feed item id of request `id` of `macID`.
    public static func itemID(macID: String, request id: String) -> String { "macreq-\(macID)-\(id)" }

    /// One `needs-you` message: the Mac's whole set of open requests.
    public func apply(_ message: Data, macID: String) {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let rows = object["items"] as? [[String: Any]] else { return }
        apply(rows.compactMap(Request.init(json:)), macID: macID)
    }

    func apply(_ requests: [Request], macID: String) {
        var next: Set<String> = []
        for request in requests {
            let item = Self.item(request, macID: macID)
            next.insert(item.id)
            store.upsert(item, atTop: true)
        }
        // Answered, cancelled or expired on the Mac: it leaves the Feed (and its push, NeedsYouNotices).
        for id in shown.subtracting(next) where store.item(id: id) != nil { store.remove(id) }
        shown = next
        store.macRequestsRead.insert(macID)
    }

    /// The link to the Mac closed: its rows stay as last read, but none counts as read now.
    public func linkClosed(macID: String) {
        store.macRequestsRead.remove(macID)
    }

    /// Reads the `needs-you` service on `link` until the channel or the link closes.
    public func read(on link: any MacLink, macID: String) async {
        do {
            let channel = try await link.openChannel(service: Self.service, args: [:])
            while let message = try await channel.receive() {
                apply(message, macID: macID)
            }
            if let closed = channel.closedBy, closed.code != "eof" {
                log.info("needs-you closed: \(closed.code, privacy: .public)")
            }
        } catch {
            log.error("needs-you channel: \(String(describing: error), privacy: .public)")
        }
        linkClosed(macID: macID)
    }

    /// `text` with every markdown punctuation mark escaped, on one line.
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isNewline { out.append(" "); continue }
            if "\\`*_{}[]()<>#+-.!|~".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// The Feed row of `request`: a pinned ask that opens its link (the PR), with what it is about.
    static func item(_ request: Request, macID: String) -> FeedItem {
        // The texts are the poster's (a PR title anyone may write): shown as text, never as markdown.
        var markdown = "**\(escaped(request.title))**"
        if let url = request.url {
            let text = request.body.isEmpty ? url.absoluteString : request.body
            markdown += "\n\n[\(escaped(text))](<\(url.absoluteString)>)"
        } else if !request.body.isEmpty {
            markdown += "\n\n" + escaped(request.body)
        }
        var item = FeedItem(
            id: itemID(macID: macID, request: request.id), kind: .needsInput, workspaceID: "", tabID: "",
            agentName: request.source.isEmpty ? "cmux" : request.source, harness: "cmux", workspaceTitle: "",
            markdown: markdown, quote: nil, createdAt: request.createdAt)
        item.macID = macID.isEmpty ? nil : macID
        item.link = request.url
        return item
    }
}
