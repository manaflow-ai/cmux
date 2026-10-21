import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextSidebar
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

    var avatar: SidebarAvatar { .account(name: name, imageData: imageData) }

    /// Adds the account rows to the profile menu (`ProfileMenuBuilder.addAccountRows`).
    @MainActor static func addRows(to menu: NSMenu, account: SidebarAccount?, registry: ActionRegistry) {
        ProfileMenuBuilder(registry: registry)
            .addAccountRows(to: menu, who: account.map { [$0.name, $0.email].compactMap(\.self) }, team: account?.team)
    }
}

/// Profile pictures by URL, fetched once each over HTTPS. Observable, so the
/// profile control swaps the initials for the picture when it arrives.
@MainActor @Observable
final class AccountAvatarImages {
    static let shared = AccountAvatarImages()
    private(set) var data: [String: Data] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    private static let maxBytes = 2 << 20

    /// Starts fetching `url` once; `data[url]` fills in when it arrives.
    func load(_ url: String?) {
        guard let url, !requested.contains(url), let remote = URL(string: url), remote.scheme == "https" else { return }
        requested.insert(url)
        // task-owner: one bounded fetch per picture URL for the app's lifetime
        Task { [weak self] in
            guard let (bytes, response) = try? await URLSession.shared.data(from: remote),
                  (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= Self.maxBytes,
                  NSImage(data: bytes) != nil else { return }
            self?.data[url] = bytes
        }
    }
}
