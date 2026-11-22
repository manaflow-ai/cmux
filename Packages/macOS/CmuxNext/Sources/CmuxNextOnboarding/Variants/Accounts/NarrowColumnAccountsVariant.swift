import AppKit
import CmuxNextDesign

/// Everything on one centered 440 pt column: title, sentence, list.
struct NarrowColumnAccounts: OnboardingScreenVariant {
    static let id = "accounts.narrow"
    static let step = OnboardingModel.Step.accounts
    static let name = "Narrow Column"
    static let summary = "Centered 28 pt title and sentence over a 440 pt list column."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let title = AccountsVariantLayout.title(AccountsVariantStrings.foundTitle, size: 28, centered: true)
        let sentence = AccountsVariantLayout.sentence(AccountsVariantStrings.privacy, centered: true)
        let list = AccountsVariantLayout.list(context)
        for view in [title, sentence, list] as [NSView] { root.addSubview(view) }
        let footer = AccountsVariantLayout.footer(context, in: root, margin: 40)
        let column: CGFloat = 440
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: column),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            sentence.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sentence.widthAnchor.constraint(lessThanOrEqualToConstant: column),
            list.topAnchor.constraint(equalTo: sentence.bottomAnchor, constant: 24),
            list.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            list.widthAnchor.constraint(equalToConstant: column),
            list.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
        ])
        return root
    }
}
