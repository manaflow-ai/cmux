import AppKit
import CmuxNextActions
import CmuxNextCloud
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
@MainActor @Observable
final class AccountAvatarImages {
    static let shared = AccountAvatarImages()
    private(set) var data: [String: Data] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    private nonisolated static let maxBytes = 2 << 20
    /// Fetches of one picture before it gives up, the first included.
    private static let attempts = 4

    /// Starts loading `url` once; `data[url]` fills in when it arrives.
    func load(_ url: String?) {
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

    private nonisolated static func isPicture(_ bytes: Data) -> Bool {
        bytes.count <= maxBytes && NSImage(data: bytes) != nil
    }
}
