import CmuxSettings
import SwiftUI

/// **Account** section — mirrors the legacy in-app section: a
/// `SettingsCard` containing the identity row (primary email title +
/// display name subtitle + Sign In / Sign Out button, no avatar),
/// followed by the cmux Pro upgrade card. The integration toggles
/// (Claude Code, Cursor, Gemini, ripgrep, subagent suppression) live
/// under **Automation** to match legacy ordering.
@MainActor
public struct AccountSection: View {
    private let accountFlow: AccountFlow?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        accountFlow: AccountFlow?
    ) {
        // `defaultsStore` and `catalog` are part of the section's shared
        // init shape (every section takes them) but the Account card binds
        // no defaults-backed values, so neither is stored. The identity row
        // is driven entirely by `accountFlow`.
        _ = defaultsStore
        _ = catalog
        self.accountFlow = accountFlow
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.account", defaultValue: "Account"), section: .account)
            SettingsCard {
                AccountIdentityCard(flow: accountFlow)
            }
            .settingsSearchAnchors(["setting:account:account"])
            SettingsCard {
                ProUpgradeCard(flow: accountFlow)
            }
            .settingsSearchAnchors(["setting:account:pro"])
        }
    }
}
