#if canImport(UIKit)
internal import UIKit

@MainActor
final class DiffLineCell: UITableViewCell {
    static let reuseIdentifier = "DiffLineCell"

    private let oldNumberLabel = UILabel()
    private let newNumberLabel = UILabel()
    private let markerLabel = UILabel()
    private let codeLabel = UILabel()
    private let rowStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 8)

        for label in [oldNumberLabel, newNumberLabel, markerLabel, codeLabel] {
            label.numberOfLines = 0
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        oldNumberLabel.textAlignment = .right
        newNumberLabel.textAlignment = .right
        markerLabel.textAlignment = .center
        codeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        codeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rowStack.axis = .horizontal
        rowStack.alignment = .firstBaseline
        rowStack.spacing = 0
        [oldNumberLabel, newNumberLabel, markerLabel, codeLabel].forEach(rowStack.addArrangedSubview)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            markerLabel.widthAnchor.constraint(equalToConstant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        line: DiffLine,
        gutterWidth: CGFloat,
        fontSize: Double,
        theme: ChangesTheme
    ) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let gutterFont = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        oldNumberLabel.font = gutterFont
        newNumberLabel.font = gutterFont
        markerLabel.font = font
        codeLabel.font = font
        oldNumberLabel.textColor = theme.gutterText.uiColor
        newNumberLabel.textColor = theme.gutterText.uiColor
        oldNumberLabel.constraints.filter { $0.firstAttribute == .width }.forEach { $0.isActive = false }
        newNumberLabel.constraints.filter { $0.firstAttribute == .width }.forEach { $0.isActive = false }
        oldNumberLabel.widthAnchor.constraint(equalToConstant: gutterWidth).isActive = true
        newNumberLabel.widthAnchor.constraint(equalToConstant: gutterWidth).isActive = true
        contentView.directionalLayoutMargins.top = CGFloat(theme.rowVerticalPadding)
        contentView.directionalLayoutMargins.bottom = CGFloat(theme.rowVerticalPadding)

        if line.kind == .noNewlineMarker {
            oldNumberLabel.isHidden = true
            newNumberLabel.isHidden = true
            markerLabel.isHidden = true
            codeLabel.attributedText = nil
            codeLabel.text = "↳ " + String(
                localized: "changes.diff.no_newline_marker",
                defaultValue: "No newline at end of file",
                bundle: .module
            )
            codeLabel.font = .preferredFont(forTextStyle: .caption2)
            codeLabel.textColor = .secondaryLabel
            backgroundColor = .clear
            return
        }

        oldNumberLabel.isHidden = line.kind == .hunkHeader
        newNumberLabel.isHidden = line.kind == .hunkHeader
        markerLabel.isHidden = line.kind == .hunkHeader
        oldNumberLabel.text = line.oldNumber.map(String.init) ?? ""
        newNumberLabel.text = line.newNumber.map(String.init) ?? ""

        switch line.kind {
        case .addition:
            markerLabel.text = "+"
            markerLabel.textColor = theme.addedStatus.uiColor
            backgroundColor = theme.additionBackground.uiColor
            codeLabel.attributedText = line.attributedCode(
                font: font,
                emphasisColor: theme.additionEmphasis.uiColor
            )
        case .removal:
            markerLabel.text = "−"
            markerLabel.textColor = theme.deletedStatus.uiColor
            backgroundColor = theme.removalBackground.uiColor
            codeLabel.attributedText = line.attributedCode(
                font: font,
                emphasisColor: theme.removalEmphasis.uiColor
            )
        case .hunkHeader:
            markerLabel.text = nil
            backgroundColor = theme.hunkHeaderBackground.uiColor
            codeLabel.attributedText = nil
            codeLabel.text = line.text
            codeLabel.textColor = theme.hunkHeaderText.uiColor
        case .context:
            markerLabel.text = nil
            backgroundColor = .clear
            codeLabel.attributedText = line.attributedCode(font: font, emphasisColor: .clear)
        case .noNewlineMarker:
            break
        }
        accessibilityLabel = [
            line.oldNumber.map { "old \($0)" },
            line.newNumber.map { "new \($0)" },
            line.text,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        backgroundColor = .clear
        codeLabel.attributedText = nil
        codeLabel.text = nil
        oldNumberLabel.isHidden = false
        newNumberLabel.isHidden = false
        markerLabel.isHidden = false
        // Width constraints are cheap but must not accumulate across font-size changes.
        oldNumberLabel.constraints.filter { $0.firstAttribute == .width }.forEach { $0.isActive = false }
        newNumberLabel.constraints.filter { $0.firstAttribute == .width }.forEach { $0.isActive = false }
    }
}
#endif
