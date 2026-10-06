import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextSidebar
import Foundation
import Observation

// The footer's account item (Leo 2026-10-06): the signed-in user's round
// avatar, and a click opens the account menu instead of a page.
extension SidebarBridge {
    /// The account menu for the footer avatar; other items run their action.
    func itemMenu(_ id: LayoutItemID) -> NSMenu? {
        guard model.layout.item(id)?.ref.builtIn == .account else { return nil }
        return SidebarFooterAccount.menu(SidebarFooterAccount(services.cloud?.auth), registry: services.registry)
    }
}

/// Who the footer avatar draws: the signed-in cmux user.
struct SidebarFooterAccount: Hashable {
    /// The display name, else the email.
    var name: String
    var email: String?
    var imageData: Data?

    /// Nil without a name or email to show.
    init?(name: String?, email: String?, imageData: Data? = nil) {
        let trimmed = [name, email].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard let trimmed else { return nil }
        self.name = trimmed
        self.email = email.flatMap { $0 == trimmed || $0.isEmpty ? nil : $0 }
        self.imageData = imageData
    }

    /// The signed-in user, with their picture once it has loaded.
    @MainActor init?(_ auth: CloudAuth?) {
        guard let auth, auth.isSignedIn, let user = auth.user else { return nil }
        let picture = user.profileImageURL.flatMap { AccountAvatarImages.shared.data[$0] }
        self.init(name: user.displayName, email: user.primaryEmail, imageData: picture)
    }

    var avatar: SidebarAvatar { SidebarAvatar(name: name, imageData: imageData) }

    /// The account menu: who is signed in (not a command), Accounts, then
    /// Sign Out. Signed out: Sign In, then Accounts. cmux has no plan to
    /// show yet, so no plan row.
    @MainActor static func menu(_ account: SidebarFooterAccount?, registry: ActionRegistry) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let add = { (id: ActionID) in
            if let item = registry.makeMenuItem(for: id) { menu.addItem(item) }
        }
        guard let account else {
            add("palette.auth.signIn")
            add("accounts.show")
            return menu
        }
        for line in [account.name, account.email].compactMap(\.self) {
            let header = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }
        menu.addItem(.separator())
        add("accounts.show")
        menu.addItem(.separator())
        add("palette.auth.signOut")
        return menu
    }
}

/// Profile pictures by URL, fetched once each over HTTPS. Observable, so the
/// footer avatar swaps the initials for the picture when it arrives.
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
