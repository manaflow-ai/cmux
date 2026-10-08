import AppKit
import CmuxNextDesign

/// The list runs edge to edge between two hairlines: a fixed header with
/// the title above, the footer below. The list scrolls under neither.
struct FullBleedAccounts: OnboardingScreenVariant {
    static let id = "accounts.fullBleed"
    static let step = OnboardingModel.Step.accounts
    static let name = "Full Bleed"
    static let summary = "Opaque; fixed title header and footer separated by hairlines, list edge to edge."
    static let surface = OnboardingSurface.glassControls
    static let transition = OnboardingTransition.none

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let title = AccountsVariantLayout.title(OnboardingStrings.accountsTitle, size: 22)
        let sentence = AccountsVariantLayout.sentence(AccountsVariantStrings.privacy)
        let top = hairline()
        let bottom = hairline()
        let list = AccountsVariantLayout.list(context)
        for view in [title, sentence, top, list, bottom] as [NSView] { root.addSubview(view) }
        let footer = AccountsVariantLayout.footer(context, in: root, margin: 32)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            sentence.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            sentence.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),
            top.topAnchor.constraint(equalTo: sentence.bottomAnchor, constant: 20),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            list.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
        ])
        return root
    }

    private static func hairline() -> NSView {
        let line = ThemedView()
        line.fill = { Palette.separator }
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}
