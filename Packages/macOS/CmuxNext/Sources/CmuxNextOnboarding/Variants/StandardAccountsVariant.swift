import AppKit

/// The landed accounts screen: the accounts feature's view under the title.
struct StandardAccounts: OnboardingScreenVariant {
    static let id = "accounts.standard"
    static let step = OnboardingModel.Step.accounts
    static let name = "Standard"
    static let summary = "The accounts list under a leading title."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.accountsTitle, subtitle: nil,
                                body: context.services.makeAccountsStepView() ?? NSView(), context: context)
    }
}
