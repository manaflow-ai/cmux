import AppKit
import CmuxNextDesign

/// A ready-made screen layout variants can use: title, one sentence, the
/// control, and the footer ("2 of 4", Skip, Continue). Every measure is on
/// the 4 pt grid; `Style` picks alignment, title scale and spacing.
@MainActor
enum OnboardingScaffold {
    struct Style: Sendable {
        enum Alignment: Sendable { case leading, center }
        var alignment: Alignment = .leading
        var titleSize: CGFloat = 22
        var titleWeight: NSFont.Weight = .semibold
        var margin: CGFloat = 40
        var titleTop: CGFloat = 52
        /// Space between the sentence and the control.
        var bodyGap: CGFloat = 28
        /// Continue with a glass bezel (else a plain push button).
        var glassContinue = true

        init() {}
    }

    /// The whole screen: `body` fills the space between the text and the footer.
    static func make(title: String, subtitle: String?, body: NSView, context: OnboardingStepContext, style: Style = Style()) -> NSView {
        let root = FlippedView()
        let titleLabel = OnboardingLabel.make(title, font: .systemFont(ofSize: style.titleSize, weight: style.titleWeight), lines: 2)
        let sentence = OnboardingLabel.make(subtitle ?? "", color: Palette.textSecondary, lines: 2)
        sentence.isHidden = subtitle == nil
        let footer = OnboardingFooter(context: context, glassContinue: style.glassContinue)
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, sentence, body, footer] as [NSView] { root.addSubview(view) }
        let centered = style.alignment == .center
        if centered {
            titleLabel.alignment = .center
            sentence.alignment = .center
        }
        let margin = style.margin
        var constraints = [
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: style.titleTop),
            sentence.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            body.topAnchor.constraint(equalTo: (subtitle == nil ? titleLabel : sentence).bottomAnchor, constant: style.bodyGap),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
        ]
        for label in [titleLabel, sentence] {
            if centered {
                constraints += [label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                                label.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -2 * margin)]
            } else {
                constraints += [label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
                                label.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -margin)]
            }
        }
        NSLayoutConstraint.activate(constraints)
        return root
    }
}

/// "2 of 4" on the left, Skip and Continue (Done on the last step, Import
/// while the import step has a choice to run) on the right.
final class OnboardingFooter: NSView {
    private let context: OnboardingStepContext
    private var loop: RenderLoop?

    init(context: OnboardingStepContext, glassContinue: Bool = true, showsCounter: Bool = true) {
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let counter = OnboardingLabel.make(OnboardingStrings.stepCounter(context.index + 1, context.count),
                                           font: OnboardingMetrics.captionFont, color: Palette.textTertiary)
        counter.isHidden = !showsCounter
        let skip = OnboardingControl.plainButton(OnboardingStrings.skip, target: self, action: #selector(skipPressed))
        let next = OnboardingControl.button(context.model.primaryTitle, prominent: glassContinue, target: self, action: #selector(nextPressed))
        for view in [counter, skip, next] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            counter.leadingAnchor.constraint(equalTo: leadingAnchor), counter.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor), next.centerYAnchor.constraint(equalTo: centerYAnchor),
            skip.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -20), skip.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 40),
        ])
        let model = context.model
        loop = RenderLoop { [weak next] in
            let title = model.primaryTitle
            if next?.title != title { next?.title = title }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func skipPressed() { context.skip() }
    @objc private func nextPressed() { context.next() }
}
