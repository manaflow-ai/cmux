import AppKit
import CmuxNextDesign

/// Opaque window, and the list alone sits on a glass card.
struct GlassCardAccounts: OnboardingScreenVariant {
    static let id = "accounts.glassCard"
    static let step = OnboardingModel.Step.accounts
    static let name = "Glass Card"
    static let summary = "Opaque; leading title and sentence, the list on a 20 pt glass card."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let card = NSView()
        AccountsVariantLayout.pin(AccountsVariantLayout.list(context), in: card, inset: 12)
        card.translatesAutoresizingMaskIntoConstraints = false
        let glass = Glass.makePanel(content: card, cornerRadius: 20)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: glass.leadingAnchor), card.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            card.topAnchor.constraint(equalTo: glass.topAnchor), card.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        let body = NSView()
        AccountsVariantLayout.pin(glass, in: body)
        var style = OnboardingScaffold.Style()
        style.margin = 40
        style.bodyGap = 20
        return OnboardingScaffold.make(title: OnboardingStrings.accountsTitle, subtitle: OnboardingStrings.accountsSubtitle,
                                       body: body, context: context, style: style)
    }
}
