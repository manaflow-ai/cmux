import CmuxSettings
import SwiftUI

/// **Account** section — mirrors the legacy in-app section: a single
/// `SettingsCard` containing the identity row (avatar + display name
/// or email + Sign In / Sign Out button). The integration toggles
/// (Claude Code, Cursor, Gemini, ripgrep, subagent suppression) live
/// under **Automation** to match legacy ordering.
@MainActor
public struct AccountSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let accountFlow: AccountFlow?

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        accountFlow: AccountFlow?
    ) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
        self.accountFlow = accountFlow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(String(localized: "settings.section.account", defaultValue: "Account"))
            SettingsCard {
                AccountIdentityCard(
                    flow: accountFlow,
                    piiModel: DefaultsValueModel(store: defaultsStore, key: catalog.account.piiDisplayMode)
                )
            }
        }
    }
}
