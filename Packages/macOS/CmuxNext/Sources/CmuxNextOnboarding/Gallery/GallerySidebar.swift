import AppKit
import CmuxNextDesign

/// The screens, one row each ("Theme  C" when picked), with the progress
/// line on top. Clicking a row selects that screen.
final class GallerySidebar: NSView {
    var onSelect: ((OnboardingModel.Step) -> Void)?
    private let progress = OnboardingLabel.make(font: OnboardingMetrics.captionFont, color: Palette.textSecondary)
    private var rows: [OnboardingModel.Step: NSButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(progress)
        stack.setCustomSpacing(16, after: progress)
        for step in OnboardingModel.Step.allCases {
            let row = NSButton(title: step.galleryName, target: self, action: #selector(pressed(_:)))
            row.isBordered = false
            row.alignment = .left
            row.tag = OnboardingModel.Step.allCases.firstIndex(of: step) ?? 0
            row.translatesAutoresizingMaskIntoConstraints = false
            rows[step] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed(_ sender: NSButton) { onSelect?(OnboardingModel.Step.allCases[sender.tag]) }

    func render(current: OnboardingModel.Step, review: GalleryReview) {
        let reviewed = OnboardingModel.Step.allCases.filter { review.picks[$0.rawValue] != nil }.count
        progress.stringValue = "\(reviewed) of \(OnboardingModel.Step.allCases.count) screens reviewed"
        for (step, row) in rows {
            let variants = step.variants
            let pick = review.picks[step.rawValue].flatMap { id in variants.firstIndex { $0.id == id } }.map(\.galleryLetter)
            let title = "\(step.galleryName)   \(pick ?? "·")   \(variants.count)"
            let selected = step == current
            row.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
                .foregroundColor: selected ? Palette.textPrimary : Palette.textSecondary,
            ])
        }
    }
}
