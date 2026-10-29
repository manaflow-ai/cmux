import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation

/// The signed-in cmux user on the sidebar's profile control (Leo 2026-10-06): their picture or
/// initials on the control, and who is signed in, on which team, with Sign Out in its menu.
struct SidebarAccount: Hashable {
    /// The display name, else the email.
    var name: String
    var email: String?
    var imageData: Data?
    /// The selected cmux team's name; its row opens the team picker.
    var team: String?

    /// Nil without a name or email to show.
    init?(name: String?, email: String?, imageData: Data? = nil, team: String? = nil) {
        let shown = [name, email].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard let shown else { return nil }
        self.name = shown
        self.email = email.flatMap { $0 == shown || $0.isEmpty ? nil : $0 }
        self.imageData = imageData
        self.team = team.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The signed-in user, with their picture once it has loaded.
    @MainActor init?(_ auth: CloudAuth?) {
        guard let auth, auth.isSignedIn, let user = auth.user else { return nil }
        let picture = user.profileImageURL.flatMap { AccountAvatarImages.shared.data[$0] }
        let team = auth.teams.first { $0.id == auth.teamID }?.displayName
        self.init(name: user.displayName, email: user.primaryEmail, imageData: picture, team: team)
    }

    var avatar: SidebarAvatar { .account(name: name, email: email, imageData: imageData) }

    /// The menu bar menu's account rows: the name, then the email, then the team.
    var menuBarAccount: MenuBarMenuState.Account { MenuBarMenuState.Account(lines: [name, email].compactMap(\.self), team: team) }

    /// Adds the account rows to the profile menu (`ProfileMenuBuilder.addAccountRows`).
    @MainActor static func addRows(to menu: NSMenu, account: SidebarAccount?, registry: ActionRegistry) {
        ProfileMenuBuilder(registry: registry)
            .addAccountRows(to: menu, who: account.map { [$0.name, $0.email].compactMap(\.self) }, team: account?.team)
    }
}

/// Profile pictures by URL: an HTTPS picture fetched once (tried again on a backoff, about 5 s,
/// 25 s and 2 min, when the fetch fails, so a launch before the network is up does not leave the
/// initials for the app's lifetime), or a `data:image/...;base64,` URL, the form Stack Auth stores an uploaded picture
/// in, decoded in place. Observable, so the profile control swaps the initials for the picture
/// when it arrives (Leo 2026-10-20: the footer showed "L" for a signed-in account).
///
/// Only the newest URL's picture is kept: the control shows one signed-in account, so a load of another
/// URL (an account switch, a new picture) forgets the older one, and a fetch of it that lands late is dropped.
@MainActor @Observable
final class AccountAvatarImages {
    static let shared = AccountAvatarImages()
    // memory: fixed one entry: only the newest loaded URL's picture, at most maxBytes (2 MiB; an avatar is tens of KB)
    private(set) var data: [String: Data] = [:]
    /// The URL ``load(_:)`` was last asked for: the one picture kept.
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var requested: Set<String> = []
    /// The last load started: its decode or fetch runs off main and stores on main (tests await it).
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    private nonisolated static let maxBytes = 2 << 20
    /// Fetches of one picture before it gives up, the first included.
    private static let attempts = 4

    /// Starts loading `url` once; `data[url]` fills in when it arrives. Another URL than the last one
    /// forgets the last one's picture.
    func load(_ url: String?) {
        guard let url, !requested.contains(url) else { return }
        if current != url {
            current = url
            requested = []
            if !data.isEmpty { data = [:] }
        }
        if let inline = Self.inlineURL(url) {
            requested.insert(url)
            // task-owner: one decode per picture URL while it is the current one; the write lands after the caller's observation read
            // main-hop-allow: the decode is @concurrent (off main); this task resumes on main once to keep the picture
            loading = Task { [weak self] in
                guard let bytes = await Self.decodedInline(inline) else { return }
                self?.store(bytes, for: url)
            }
            return
        }
        guard let remote = URL(string: url), remote.scheme == "https" else { return }
        requested.insert(url)
        // task-owner: one bounded fetch per picture URL while it is the current one, with a few spaced retries
        // main-hop-allow: each fetch and its decode are @concurrent (off main); this task resumes on main once per attempt to keep the picture
        loading = Task { [weak self] in
            var backoff = Backoff(initial: .seconds(5), maximum: .seconds(120), multiplier: 5)
            for attempt in 1...Self.attempts {
                if let bytes = await Self.fetch(remote) {
                    self?.store(bytes, for: url)
                    return
                }
                guard attempt < Self.attempts, self?.current == url else { return }
                // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                do { try await backoff.wait(owner: "sidebar.accountAvatar") } catch { return }
            }
        }
    }

    /// Keeps `bytes` as `url`'s picture while `url` is still the current one.
    private func store(_ bytes: Data, for url: String) {
        guard url == current else { return }
        data = [url: bytes]
    }

    /// The picture at `remote`, off the main actor (the image check decodes it).
    @concurrent private nonisolated static func fetch(_ remote: URL) async -> Data? {
        guard let (bytes, response) = try? await URLSession.shared.data(from: remote),
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

    /// ``decodeInline(_:)`` off the main actor.
    @concurrent private nonisolated static func decodedInline(_ payload: Substring) async -> Data? {
        decodeInline(payload)
    }

    private nonisolated static func isPicture(_ bytes: Data) -> Bool {
        bytes.count <= maxBytes && blockingNSImage(bytes) != nil
    }
}
