import Foundation

/// The built-in agent logos a user can set as a workspace avatar from the macOS
/// workspace context menu. Each `id` is a stable identifier that travels to iOS
/// inside the workspace `avatar` field as `"logo:<id>"` (see
/// `MacAvatarIcon.logoValue` on the iOS side). The identifiers must stay in sync
/// with `WorkspaceAgentLogo` in `Packages/iOS/CmuxMobileShellUI` — that package
/// owns the bundled image assets that render these logos on the phone.
enum WorkspaceAvatarCatalog {
    /// Prefix that encodes a built-in logo id into the stored/synced avatar
    /// string. Mirrors `MacAvatarIcon.logoPrefix` on iOS.
    static let logoPrefix = "logo:"

    struct Logo: Identifiable, Hashable {
        /// Stable identifier (never change once shipped).
        let id: String
        /// Localized display name for the menu item.
        let displayName: String
        /// Representative SF Symbol shown beside the menu item (the branded image
        /// itself is bundled and rendered only on the phone today).
        let menuSymbol: String

        /// The stored/synced avatar string for this logo, e.g. `"logo:claude"`.
        var avatarValue: String { WorkspaceAvatarCatalog.logoPrefix + id }
    }

    /// All built-in logos, in menu order.
    static let logos: [Logo] = [
        Logo(
            id: "claude",
            displayName: String(localized: "workspaceAvatar.claude", defaultValue: "Claude"),
            menuSymbol: "sparkle"
        ),
        Logo(
            id: "codex",
            displayName: String(localized: "workspaceAvatar.codex", defaultValue: "Codex"),
            menuSymbol: "chevron.left.forwardslash.chevron.right"
        ),
        Logo(
            id: "opencode",
            displayName: String(localized: "workspaceAvatar.opencode", defaultValue: "OpenCode"),
            menuSymbol: "curlybraces"
        ),
        Logo(
            id: "pi",
            displayName: String(localized: "workspaceAvatar.pi", defaultValue: "pi"),
            menuSymbol: "function"
        ),
        Logo(
            id: "terminal",
            displayName: String(localized: "workspaceAvatar.terminal", defaultValue: "Terminal"),
            menuSymbol: "terminal"
        ),
    ]

    /// The logo currently selected by a workspace avatar string, if it names a
    /// built-in logo. `nil` for cleared, emoji, or SF-Symbol avatars.
    static func selectedLogo(for avatar: String?) -> Logo? {
        guard let avatar, avatar.hasPrefix(logoPrefix) else { return nil }
        let id = String(avatar.dropFirst(logoPrefix.count))
        return logos.first { $0.id == id }
    }
}
