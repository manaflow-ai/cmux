import AppKit
import CmuxNextDesign

/// A row with a round check (filled in the foreground color when on), a
/// title and a caption. The whole row is the hit target.
final class CheckRowView: SelectableCard {
    var onToggle: (() -> Void)?
    var isChecked = false { didSet { updateCheck() } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }
    let hasData: Bool
    private let mark = ThemedView()
    private let glyph = NSImageView()

    init(title: String, caption: String, hasData: Bool) {
        self.hasData = hasData
        super.init(frame: .zero)
        selection = .hover
        let side = Metrics.iconSize + 2
        mark.cornerRadius = side / 2
        mark.borderWidth = 1.5
        glyph.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side * 0.55, weight: .bold))
        glyph.contentTintColor = Palette.textOnPrimary
        glyph.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(glyph)
        let titleLabel = OnboardingLabel.make(title, font: Typography.bodyEmphasized)
        let captionLabel = OnboardingLabel.make(caption, font: Typography.caption, color: Palette.textTertiary)
        let text = NSStackView(views: [titleLabel, captionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.space1
        let row = NSStackView(views: [mark, text])
        row.spacing = Metrics.space5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: side), mark.heightAnchor.constraint(equalToConstant: side),
            glyph.centerXAnchor.constraint(equalTo: mark.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space5),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.space4),
        ])
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        onSelect = { [weak self] in
            guard let self, isEnabled else { return }
            onToggle?()
        }
        updateCheck()
    }

    private func updateCheck() {
        let checked = isChecked
        mark.fill = { checked ? Palette.textPrimary : nil }
        mark.border = { checked ? Palette.textPrimary : Palette.textTertiary }
        glyph.isHidden = !checked
        setAccessibilityValue(checked)
    }
}
