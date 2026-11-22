import AppKit
import CmuxNextDesign

/// One large title and the list; no sentence, so the list gets the room.
struct TitleOnlyAccounts: OnboardingScreenVariant {
    static let id = "accounts.titleOnly"
    static let step = OnboardingModel.Step.accounts
    static let name = "Title Only"
    static let summary = "Floating glass panel, 34 pt bold title, no sentence, tall list."
    static let surface = OnboardingSurface.glassPanel
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        var style = OnboardingScaffold.Style()
        style.titleSize = 34
        style.titleWeight = .bold
        style.margin = 44
        style.titleTop = 44
        style.bodyGap = 20
        return OnboardingScaffold.make(title: OnboardingStrings.accountsTitle, subtitle: nil,
                                       body: AccountsVariantLayout.list(context), context: context, style: style)
    }
}
