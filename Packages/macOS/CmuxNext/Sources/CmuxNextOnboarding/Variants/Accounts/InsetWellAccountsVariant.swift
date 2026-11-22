import AppKit
import CmuxNextDesign

/// Glass window; the list sits in an opaque, inset rounded well so its
/// rows read on a steady background whatever is behind the window.
struct InsetWellAccounts: OnboardingScreenVariant {
    static let id = "accounts.well"
    static let step = OnboardingModel.Step.accounts
    static let name = "Inset Well"
    static let summary = "Full glass; the list in an opaque 12 pt well with a hairline border."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let well = ThemedView()
        well.cornerRadius = 12
        well.fill = { Palette.pageBackground }
        well.border = { Palette.separator }
        well.layer?.masksToBounds = true
        AccountsVariantLayout.pin(AccountsVariantLayout.list(context), in: well, inset: 8)
        var style = OnboardingScaffold.Style()
        style.margin = 32
        style.titleTop = 48
        style.bodyGap = 20
        return OnboardingScaffold.make(title: OnboardingStrings.accountsTitle, subtitle: AccountsVariantStrings.privacy,
                                       body: well, context: context, style: style)
    }
}
