import CmuxNextRemoteFetch
import Foundation

/// Pull request authors' GitHub avatars for the hover card, as `data:` URLs (Leo 2026-11-07: "can
/// you not just also pull the GitHub icon for the profile picture?"): a cmux page's CSP loads no
/// remote image (`img-src data:`), so the host fetches the image and the page draws it inline, as
/// favicons are drawn (`AppServices.dataURL`).
///
/// An avatar is not a GitHub API call and costs no quota, but the loads are still bounded: only
/// https on ``host``, every redirect too (``AgentPaneSafeFetch/fetch(_:within:)``); one load in
/// flight per login; a load that fails is not tried again for ``failureRetry``; at most
/// ``maximumBytes`` of PNG, JPEG, GIF or WebP. A card never waits on one: ``image(login:address:)``
/// answers what is held and starts the load, and a later ask (the card asks again while the
/// pull request is being read, and on its next open) has it.
///
/// In memory only, so there is no ETag revalidation: a held image is kept ``kept``, and GitHub
/// gives a changed avatar a new link (its `v=`), which is a new load at once.
@MainActor
final class AgentReplyAvatars {
    typealias Fetch = @Sendable (URL) async -> Data?

    private struct Entry {
        /// The link the image came from; a different link for the login is a new load.
        var address: String
        /// The image as a `data:` URL; nil until a load succeeds.
        var image: String?
        /// When the last load finished, good or not.
        var at: ContinuousClock.Instant
        /// The last load failed, so the next waits ``failureRetry``.
        var failed: Bool
    }

    /// The one host an avatar loads from.
    nonisolated static let host = "avatars.githubusercontent.com"
    /// The largest avatar taken, about 16 KB; a 48 px avatar is a few KB.
    nonisolated static let maximumBytes = 16 << 10
    /// How long a failed load waits before the next.
    static let failureRetry: Duration = .seconds(600)
    /// How long a held image is served before it is loaded again: a day. People rarely change
    /// their avatar, and a change comes with a new link, which loads at once.
    static let kept: Duration = .seconds(86_400)
    /// The most logins held; the stalest goes first.
    static let maximumKept = 200

    private let fetch: Fetch
    private let now: @MainActor () -> ContinuousClock.Instant
    private var entries: [String: Entry] = [:]
    private var inflight: [String: Task<Void, Never>] = [:]

    init(fetch: @escaping Fetch = AgentReplyAvatars.guardedFetch,
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.fetch = fetch
        self.now = now
    }

    /// `address` when it is exactly an https link on ``host`` (no user, no other port), else nil.
    nonisolated static func allowedURL(_ address: String) -> URL? {
        guard address.hasPrefix("https://\(host)/"), let url = URL(string: address),
              GuardedRemoteFetch.isListed(url, in: [host]) else { return nil }
        return url
    }

    /// The avatar of `login` at `address` as a `data:` URL when one is held. When none is, or it
    /// is old, starts its load (unless one is running or the last failed within ``failureRetry``)
    /// and answers what is held meanwhile. Never waits.
    func image(login: String, address: String) -> String? {
        guard !login.isEmpty, let url = Self.allowedURL(address) else { return nil }
        let entry = entries[login].flatMap { $0.address == address ? $0 : nil }
        if let entry, now() - entry.at < (entry.failed ? Self.failureRetry : Self.kept) { return entry.image }
        if inflight[login] == nil {
            let fetch = fetch
            // task-owner: one avatar load per login; every card of that author shares it.
            inflight[login] = Task { [weak self] in
                let data = await fetch(url)
                self?.finish(login, address: address, data: data)
            }
        }
        return entry?.image
    }

    /// Whether `login`'s avatar is loading now. A load ends within the fetch's timeout.
    func loading(_ login: String) -> Bool {
        inflight[login] != nil
    }

    /// Waits for `login`'s load when one runs, for the tests.
    func loaded(_ login: String) async {
        await inflight[login]?.value
    }

    private func finish(_ login: String, address: String, data: Data?) {
        inflight[login] = nil
        let image = data.flatMap(Self.dataURL)
        // A failed reload keeps the image it had for the same link.
        let held = entries[login].flatMap { $0.address == address ? $0.image : nil }
        entries[login] = Entry(address: address, image: image ?? held, at: now(), failed: image == nil)
        while entries.count > Self.maximumKept,
              let stalest = entries.filter({ inflight[$0.key] == nil }).min(by: { $0.value.at < $1.value.at })?.key {
            entries[stalest] = nil
        }
    }

    /// `data` as a `data:` URL of its real type, sniffed from its first bytes rather than taken
    /// from a header: PNG, JPEG, GIF or WebP only, at most ``maximumBytes``; nil for anything else.
    nonisolated static func dataURL(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumBytes, let type = imageType(data) else { return nil }
        return "data:\(type);base64," + data.base64EncodedString()
    }

    /// The image type `data` starts as, by its magic bytes.
    nonisolated static func imageType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), bytes.dropFirst(8).elementsEqual("WEBP".utf8) { return "image/webp" }
        return nil
    }

    /// The real load: the reply image fetch's network rules (``AgentPaneSafeFetch``), held to
    /// ``host`` on every hop and to ``maximumBytes``.
    nonisolated static let guardedFetch: Fetch = { url in
        var safe = AgentPaneSafeFetch()
        safe.guarded.maximumBytes = AgentReplyAvatars.maximumBytes
        guard case .success(let data) = await safe.fetch(url, within: [AgentReplyAvatars.host]) else { return nil }
        return data
    }
}
