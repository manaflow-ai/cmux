import AppKit
import CmuxEgress
import CmuxNextWakeups
public import Foundation
public import Observation

/// Profile pictures by URL: an HTTPS picture fetched once (tried again on a backoff, about 5 s,
/// 25 s and 2 min, when the fetch fails, so a launch before the network is up does not leave the
/// initials for the app's lifetime), or a `data:image/...;base64,` URL, the form Stack Auth stores an uploaded picture
/// in, decoded in place. Observable, so the profile control swaps the initials for the picture
/// when it arrives (Leo 2026-10-20: the footer showed "L" for a signed-in account).
@MainActor @Observable
public final class AccountAvatarImages {
    public static let shared = AccountAvatarImages()
    public private(set) var data: [String: Data] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    private nonisolated static let maxBytes = 2 << 20
    /// Fetches of one picture before it gives up, the first included.
    private static let attempts = 4

    /// Starts loading `url` once; `data[url]` fills in when it arrives.
    public func load(_ url: String?) {
        guard let url, !requested.contains(url) else { return }
        if let inline = Self.inlineURL(url) {
            requested.insert(url)
            // task-owner: one decode per picture URL for the app's lifetime; the write lands after the caller's observation read
            Task { [weak self] in
                guard let bytes = Self.decodeInline(inline) else { return }
                self?.data[url] = bytes
            }
            return
        }
        guard let remote = URL(string: url), remote.scheme == "https" else { return }
        requested.insert(url)
        // task-owner: one bounded fetch per picture URL for the app's lifetime, with a few spaced retries
        Task { [weak self] in
            var backoff = Backoff(initial: .seconds(5), maximum: .seconds(120), multiplier: 5)
            for attempt in 1...Self.attempts {
                if let bytes = await Self.fetch(remote) {
                    self?.data[url] = bytes
                    return
                }
                guard attempt < Self.attempts, self != nil else { return }
                // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                do { try await backoff.wait(owner: "sidebar.accountAvatar") } catch { return }
            }
        }
    }

    private static func fetch(_ remote: URL) async -> Data? {
        guard let (bytes, response) = try? await CmuxEgress.shared(site: "CmuxNextAccounts.AccountAvatarImages").data(from: remote),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return isPicture(bytes) ? bytes : nil
    }

    /// The base64 payload of a `data:image/<type>;base64,<payload>` URL; nil for any other URL.
    nonisolated static func inlineURL(_ url: String) -> Substring? {
        guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.split(separator: ";").contains("base64") else { return nil }
        return url[url.index(after: comma)...]
    }

    /// The picture's bytes from an inline URL's payload, when they decode to an image within the size cap.
    nonisolated static func decodeInline(_ payload: Substring) -> Data? {
        guard payload.count <= maxBytes * 4 / 3 + 4,
              let bytes = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters) else { return nil }
        return isPicture(bytes) ? bytes : nil
    }

    private nonisolated static func isPicture(_ bytes: Data) -> Bool {
        bytes.count <= maxBytes && NSImage(data: bytes) != nil
    }
}
