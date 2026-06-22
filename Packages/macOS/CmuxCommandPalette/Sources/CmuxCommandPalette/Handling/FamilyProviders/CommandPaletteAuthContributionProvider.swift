import Foundation

/// Builds the Auth-domain palette contribution slice (Sign In and Sign Out).
/// The provider owns the *structure* (command identifiers, keywords, and the
/// `when` gates over the ``CommandPaletteContextKeys/authSignedIn`` and
/// ``CommandPaletteContextKeys/authWorking`` snapshot keys); the localized
/// titles and the shared "Account" subtitle are resolved app-side and handed in
/// through ``Strings``.
///
/// The sign-in / sign-out handlers stay app-side behind
/// ``CommandPaletteActionHandling`` because they drive the app's auth runtime.
public struct CommandPaletteAuthContributionProvider {
    /// Stable identifier for the sign-in command.
    public static let signInCommandId = "palette.auth.signIn"
    /// Stable identifier for the sign-out command.
    public static let signOutCommandId = "palette.auth.signOut"

    /// App-resolved display text for the Auth slice.
    public struct Strings: Sendable, Equatable {
        /// "Sign In" title.
        public let signInTitle: String
        /// "Sign Out" title.
        public let signOutTitle: String
        /// Shared "Account" subtitle for both commands.
        public let subtitle: String

        /// Creates the resolved Auth strings.
        public init(signInTitle: String, signOutTitle: String, subtitle: String) {
            self.signInTitle = signInTitle
            self.signOutTitle = signOutTitle
            self.subtitle = subtitle
        }
    }

    /// Creates the provider. It is stateless; the catalog is baked into ``build``.
    public init() {}

    /// Assembles the Auth-domain contribution slice in its legacy order.
    public func build(strings: Strings) -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: Self.signInCommandId,
                title: constant(strings.signInTitle),
                subtitle: constant(strings.subtitle),
                keywords: ["account", "auth", "authenticate", "authentication", "login", "log in", "signin", "sign in"],
                when: { context in
                    !context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: Self.signOutCommandId,
                title: constant(strings.signOutTitle),
                subtitle: constant(strings.subtitle),
                keywords: ["account", "auth", "logout", "log out", "signout", "sign out"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
        ]
    }
}
