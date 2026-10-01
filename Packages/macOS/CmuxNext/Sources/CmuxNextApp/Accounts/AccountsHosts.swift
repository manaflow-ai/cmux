import CmuxNextAccounts
import CmuxNextDesign
import SwiftUI

// The Accounts screen inside its hosts: Settings > Accounts here, and the
// onboarding step once the onboarding window offers its hook.
extension SettingsWindowService {
    func accountsView(tokens: ThemeTokens) -> AnyView? {
        AnyView(AccountsSectionView(model: services.accounts.model, palette: AccountsPalette(tokens: tokens)))
    }
}
