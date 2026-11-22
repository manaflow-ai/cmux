import AppKit
import CmuxNextDesign

/// Editorial: a narrow left column carries the title and the full
/// sentence; the list takes the right two thirds, top to footer.
struct EditorialSplitAccounts: OnboardingScreenVariant {
    static let id = "accounts.split"
    static let step = OnboardingModel.Step.accounts
    static let name = "Editorial Split"
    static let summary = "Opaque; title and sentence in a 192 pt left column, list on the right."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let title = AccountsVariantLayout.title(OnboardingStrings.accountsTitle, size: 28)
        let list = AccountsVariantLayout.list(context)
        for view in [title, list] as [NSView] { root.addSubview(view) }
        let footer = AccountsVariantLayout.footer(context, in: root, margin: 40)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 56),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 192),
            title.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 264),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -36),
            list.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
        ])
        return root
    }
}
