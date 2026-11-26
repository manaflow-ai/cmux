import AppKit
public import CmuxNextCloud
import CmuxNextCompat
public import CmuxNextDesign
import Observation

/// The signed-in account on a live wallpaper's badge (Leo: "hanging badge with the user's name and
/// avatar"): every backdrop in the app, each window's and each pane's own copy of the art, shows the
/// account's name, then its picture once ``AccountAvatarImages`` has it; signed out, this Mac's user
/// (``LiveWallpaperBadgeIdentity/macUser``). It only says who a badge shows: a backdrop draws one only
/// while a scene with a badge slot runs (``BackdropLiveView/badgeIdentity``), so no other look changes.
/// The app makes one (`AppServices.wallpaperBadge`) and hands it to each window and pane.
@MainActor
public final class AccountWallpaperBadge {
    /// Who the badges show now.
    public private(set) var identity: LiveWallpaperBadgeIdentity = .macUser
    private let views = NSHashTable<WindowMaterialView>.weakObjects()
    private var observation: Task<Void, Never>?

    /// Follows the signed-in account of `auth` (the app's one account store), with its picture from `avatars`.
    public init(auth: CloudAuth, avatars: AccountAvatarImages) {
        // task-owner: one account observation for the app's lifetime; event-driven (Observation)
        observation = Task { [weak self] in
            for await identity in ObservationStream({ Self.identity(auth, avatars: avatars) }) {
                self?.apply(identity)
            }
        }
    }

    /// Shows the account on `view`'s badge, now and on each change (held weakly).
    public func add(_ view: WindowMaterialView) {
        views.add(view)
        view.liveView.badgeIdentity = identity
    }

    private func apply(_ identity: LiveWallpaperBadgeIdentity) {
        self.identity = identity
        for view in views.allObjects { view.liveView.badgeIdentity = identity }
    }

    /// The signed-in user's name and loaded picture (starting its fetch), else this Mac's user.
    /// The picture stays encoded here; the badge decodes it off the main thread.
    static func identity(_ auth: CloudAuth, avatars: AccountAvatarImages) -> LiveWallpaperBadgeIdentity {
        guard auth.isSignedIn, let user = auth.user else { return .macUser }
        avatars.load(user.profileImageURL)
        guard let name = AccountName(name: user.displayName, email: user.primaryEmail) else { return .macUser }
        return LiveWallpaperBadgeIdentity(name: name.text, imageData: user.profileImageURL.flatMap { avatars.data[$0] })
    }
}

/// The name an account shows: its display name, else its email, trimmed. The sidebar's account
/// (`SidebarAccount`) and the wallpaper badge both use it.
public nonisolated struct AccountName: Sendable, Hashable {
    public let text: String

    /// Nil when neither has text.
    public init?(name: String?, email: String?) {
        let shown = [name, email].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard let shown else { return nil }
        text = shown
    }
}
