import AppKit
import CmuxNextDesign

/// The screen layout: title, one sentence, the control, and the footer
/// (Skip, then the primary button). Every measure is on the 4 pt grid.
@MainActor
enum OnboardingScaffold {
    /// The whole screen: `body` fills the space between the text and the footer.
    static func make(title: String, subtitle: String?, body: NSView, context: OnboardingStepContext) -> NSView {
        let root = FlippedView()
        let titleLabel = OnboardingLabel.make(title, font: OnboardingMetrics.titleFont, lines: 2)
        let sentence = OnboardingLabel.make(subtitle ?? "", color: Palette.textSecondary, lines: 2)
        sentence.isHidden = subtitle == nil
        let footer = OnboardingFooter(context: context)
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, sentence, body, footer] as [NSView] { root.addSubview(view) }
        let margin = OnboardingMetrics.margin
        var constraints = [
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            sentence.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            body.topAnchor.constraint(equalTo: (subtitle == nil ? titleLabel : sentence).bottomAnchor, constant: 28),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
        ]
        for label in [titleLabel, sentence] {
            constraints += [label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
                            label.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -margin)]
        }
        NSLayoutConstraint.activate(constraints)
        return root
    }
}

/// Skip and the primary button (Done, Find Browsers or Import) on the right.
final class OnboardingFooter: NSView {
    private let context: OnboardingStepContext
    private var loop: RenderLoop?

    init(context: OnboardingStepContext) {
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let skip = OnboardingControl.plainButton(OnboardingStrings.skip, target: self, action: #selector(skipPressed))
        let next = OnboardingControl.button(context.model.primaryTitle, prominent: true, target: self, action: #selector(nextPressed))
        for view in [skip, next] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            next.trailingAnchor.constraint(equalTo: trailingAnchor), next.centerYAnchor.constraint(equalTo: centerYAnchor),
            skip.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -20), skip.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 40),
        ])
        let model = context.model
        loop = RenderLoop { [weak next] in
            let title = model.primaryTitle
            if next?.title != title {
                next?.title = title
                (next as? OnboardingAccentButton)?.refreshAppearance()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func skipPressed() { context.skip() }
    @objc private func nextPressed() { context.next() }
}
