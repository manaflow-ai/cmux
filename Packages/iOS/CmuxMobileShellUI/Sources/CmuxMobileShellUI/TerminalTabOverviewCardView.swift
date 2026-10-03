#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

@MainActor
final class TerminalTabOverviewCardView: UIControl {
    var onSelect: ((MobileTerminalPreview.ID) -> Void)?
    var onClose: ((MobileTerminalPreview.ID) -> Void)?

    private var item: TerminalTabOverviewItem
    private let surface = UIView()
    private let preview = UIView()
    private let bottomTitleLabel = UILabel()
    private let groupIcon = UIImageView(image: UIImage(systemName: "square.grid.3x3.fill"))
    private let closeButton = UIButton(type: .system)
    private let lineStack = UIStackView()
    private var terminalSnapshot: UIView?

    var transitionPreview: UIView { preview }

    init(item: TerminalTabOverviewItem, canClose: Bool) {
        self.item = item
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        configure()
        update(item: item, canClose: canClose)
    }

    var itemTitle: String { item.title }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(item: TerminalTabOverviewItem, canClose: Bool) {
        self.item = item
        accessibilityLabel = item.title
        accessibilityTraits = item.isSelected ? [.button, .selected] : .button
        accessibilityIdentifier = "MobileTerminalOverviewCard-\(item.id.rawValue)"
        closeButton.isHidden = !canClose
        closeButton.accessibilityIdentifier = "MobileTerminalOverviewClose-\(item.id.rawValue)"
        bottomTitleLabel.text = item.title
        lineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let lines = item.previewLines.prefix(10)
        if lines.isEmpty {
            lineStack.addArrangedSubview(makeLine("No preview yet", muted: true))
        } else {
            for line in lines {
                lineStack.addArrangedSubview(makeLine(line.isEmpty ? " " : line, muted: false))
            }
        }
        setNeedsLayout()
    }

    private func configure() {
        backgroundColor = UIColor.secondarySystemBackground
        layer.cornerRadius = 19
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.13
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.masksToBounds = false
        addTarget(self, action: #selector(selected), for: .touchUpInside)

        surface.backgroundColor = .systemBackground
        surface.layer.cornerRadius = 15
        surface.layer.masksToBounds = true
        // Let the card control own taps everywhere except its explicit close
        // button. Without this, UIKit hit-tests the preview container and a
        // tap on the card body never reaches UIControl.touchUpInside.
        surface.isUserInteractionEnabled = false
        addSubview(surface)

        preview.backgroundColor = UIColor(red: 0.075, green: 0.08, blue: 0.09, alpha: 1)
        preview.layer.cornerRadius = 12
        preview.layer.masksToBounds = true
        surface.addSubview(preview)

        lineStack.axis = .vertical
        lineStack.alignment = .fill
        lineStack.distribution = .fill
        lineStack.spacing = 1
        preview.addSubview(lineStack)


        bottomTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        bottomTitleLabel.textColor = .label
        bottomTitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(bottomTitleLabel)

        groupIcon.tintColor = .secondaryLabel
        groupIcon.contentMode = .scaleAspectFit
        addSubview(groupIcon)

        // Card close controls use Safari's filled SF Symbol. Keeping this as
        // an image preserves the symbol's native gray circle and avoids a
        // hand-painted background behind the card preview.
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22, weight: .regular),
            forImageIn: .normal
        )
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = L10n.string("mobile.terminal.overview.close", defaultValue: "Close Terminal")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)
    }

    private func makeLine(_ text: String, muted: Bool) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = muted ? UIColor.white.withAlphaComponent(0.48) : UIColor.white.withAlphaComponent(0.88)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// Retains UIKit's rendered terminal snapshot, including Metal content.
    func setTerminalSnapshot(_ snapshot: UIView) {
        terminalSnapshot?.removeFromSuperview()
        terminalSnapshot = snapshot
        snapshot.isUserInteractionEnabled = false
        snapshot.layer.anchorPoint = .zero
        preview.addSubview(snapshot)
        lineStack.isHidden = true
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 36))
        preview.frame = surface.bounds
        closeButton.frame = CGRect(x: bounds.width - 38, y: 2, width: 36, height: 36)
        lineStack.frame = preview.bounds.insetBy(dx: 9, dy: 14)
        if let snapshot = terminalSnapshot, snapshot.bounds.width > 0 {
            snapshot.layer.position = .zero
            let scale = preview.bounds.width / snapshot.bounds.width
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        let bottomY = bounds.height - 26
        groupIcon.frame = CGRect(x: 12, y: bottomY, width: 16, height: 16)
        bottomTitleLabel.frame = CGRect(x: 34, y: bottomY - 2, width: max(0, bounds.width - 44), height: 22)
    }

    @objc private func selected() {
        onSelect?(item.id)
    }

    @objc private func closeTapped() {
        onClose?(item.id)
    }

}
#endif
