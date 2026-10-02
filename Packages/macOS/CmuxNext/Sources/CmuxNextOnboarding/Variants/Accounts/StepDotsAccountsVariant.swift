import AppKit
import CmuxNextDesign

/// Centered title and sentence, the list on generous 64 pt margins, and a
/// footer that shows progress as dots instead of "4 of 4".
struct StepDotsAccounts: OnboardingScreenVariant {
    static let id = "accounts.dots"
    static let step = OnboardingModel.Step.accounts
    static let name = "Step Dots"
    static let summary = "Opaque; centered text, 64 pt margins, footer with step dots."
    static let surface = OnboardingSurface.opaque
    static let transition = OnboardingTransition.none

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let title = AccountsVariantLayout.title(OnboardingStrings.accountsTitle, size: 22, centered: true)
        let sentence = AccountsVariantLayout.sentence(AccountsVariantStrings.privacy, centered: true)
        let list = AccountsVariantLayout.list(context)
        let footer = AccountsVariantLayout.footer(context, in: root, margin: 40, showsCounter: false)
        let dots = AccountsStepDots(index: context.index, count: context.count)
        for view in [title, sentence, list, dots] as [NSView] { root.addSubview(view) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -128),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            sentence.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sentence.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -128),
            list.topAnchor.constraint(equalTo: sentence.bottomAnchor, constant: 24),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 64),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -64),
            list.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            dots.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            dots.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        return root
    }
}

/// One 6 pt dot per step: the current one in the primary text color, the
/// rest in the separator color.
final class AccountsStepDots: NSStackView {
    init(index: Int, count: Int) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        for step in 0..<count {
            let dot = ThemedView()
            dot.cornerRadius = 3
            dot.fill = step == index ? { Palette.textPrimary } : { Palette.separator }
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)])
            addArrangedSubview(dot)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(OnboardingStrings.stepCounter(index + 1, count))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
