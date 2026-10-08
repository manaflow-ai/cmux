import AppKit
import CmuxNextDesign

/// Layout pieces the Accounts variants share. The list itself is the
/// accounts feature's view (`makeAccountsStepView`); variants only place it.
@MainActor
enum AccountsVariantLayout {
    /// The accounts list (an empty view when the App supplies none).
    static func list(_ context: OnboardingStepContext) -> NSView {
        let list = context.services.makeAccountsStepView() ?? NSView()
        list.translatesAutoresizingMaskIntoConstraints = false
        return list
    }

    static func title(_ text: String, size: CGFloat, weight: NSFont.Weight = .semibold, centered: Bool = false) -> NSTextField {
        let label = OnboardingLabel.make(text, font: .systemFont(ofSize: size, weight: weight), lines: 2)
        if centered { label.alignment = .center }
        return label
    }

    static func sentence(_ text: String, centered: Bool = false, lines: Int = 2) -> NSTextField {
        let label = OnboardingLabel.make(text, color: Palette.textSecondary, lines: lines)
        if centered { label.alignment = .center }
        return label
    }

    /// Pins `view` inside `container` with `inset` on every side.
    static func pin(_ view: NSView, in container: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if view.superview !== container { container.addSubview(view) }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }

    /// The standard footer along `root`'s bottom edge.
    @discardableResult
    static func footer(_ context: OnboardingStepContext, in root: NSView, margin: CGFloat, showsCounter: Bool = true) -> NSView {
        let footer = OnboardingFooter(context: context, showsCounter: showsCounter)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
        ])
        return footer
    }
}

/// Copy only the Accounts variants use (OnboardingVariantsAccounts.xcstrings).
enum AccountsVariantStrings {
    static var foundTitle: String {
        String(localized: "onboarding.v.accounts.foundTitle", defaultValue: "Sign-ins on this Mac",
               table: "OnboardingVariantsAccounts", bundle: .module)
    }
    static var privacy: String {
        String(localized: "onboarding.v.accounts.privacy", defaultValue: "Nothing is uploaded unless you choose Connect.",
               table: "OnboardingVariantsAccounts", bundle: .module)
    }
}
