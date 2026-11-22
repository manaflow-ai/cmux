import AppKit
import CmuxNextDesign

/// Apple setup assistant: centered bold title and sentence, a centered
/// list column, and one wide centered Continue with Skip under it.
struct SetupAssistantAccounts: OnboardingScreenVariant {
    static let id = "accounts.setupAssistant"
    static let step = OnboardingModel.Step.accounts
    static let name = "Setup Assistant"
    static let summary = "Centered bold title, 460 pt list, wide centered Continue with Skip below."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.slide

    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let title = AccountsVariantLayout.title(AccountsVariantStrings.foundTitle, size: 28, weight: .bold, centered: true)
        let sentence = AccountsVariantLayout.sentence(AccountsVariantStrings.privacy, centered: true)
        let list = AccountsVariantLayout.list(context)
        let footer = SetupAssistantAccountsFooter(context: context)
        for view in [title, sentence, list, footer] as [NSView] { root.addSubview(view) }
        let column: CGFloat = 460
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            title.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: column),
            sentence.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            sentence.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sentence.widthAnchor.constraint(lessThanOrEqualToConstant: column),
            list.topAnchor.constraint(equalTo: sentence.bottomAnchor, constant: 20),
            list.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            list.widthAnchor.constraint(equalToConstant: column),
            list.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            footer.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -80),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        return root
    }
}

/// A 240 pt glass Continue (Done on the last step) with a plain Skip under it.
final class SetupAssistantAccountsFooter: NSView {
    private let context: OnboardingStepContext

    init(context: OnboardingStepContext) {
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let next = OnboardingControl.button(context.isLast ? OnboardingStrings.done : OnboardingStrings.continueButton,
                                            prominent: true, target: self, action: #selector(nextPressed))
        let skip = OnboardingControl.plainButton(OnboardingStrings.skip, target: self, action: #selector(skipPressed))
        let stack = NSStackView(views: [next, skip])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            next.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func nextPressed() { context.next() }
    @objc private func skipPressed() { context.skip() }
}
