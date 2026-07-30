import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Recycled pure-AppKit History group header, floated by `NSTableView`.
@MainActor
final class VaultHistoryTableGroupCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("VaultHistoryTableGroupCellView")

    private let backgroundView = NSVisualEffectView()
    private let iconView = CmuxResolvedIconImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconToTitleConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .sidebar
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .followsWindowActiveState
        addSubview(backgroundView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setAccessibilityElement(false)
        addSubview(countLabel)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 0)
        iconToTitleConstraint = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor)
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconView.heightAnchor.constraint(equalToConstant: 12),

            iconToTitleConstraint,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.apply(nil)
    }

    func configure(
        id: String,
        title: String,
        count: Int,
        agent: SessionAgent?,
        globalFontMagnificationPercent: Int
    ) {
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        titleLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(11, percent: globalFontMagnificationPercent),
            weight: .semibold
        )
        countLabel.stringValue = count.formatted()
        countLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(10, percent: globalFontMagnificationPercent)
        )
        configureIcon(agent)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("VaultHistoryGroup:\(id)")
        setAccessibilityLabel("\(title), \(count.formatted())")
    }

    private func configureIcon(_ agent: SessionAgent?) {
        guard let agent else {
            iconView.apply(nil)
            iconWidthConstraint.constant = 0
            iconToTitleConstraint.constant = 0
            return
        }
        let source: CmuxResolvedIconSource
        if let assetName = agent.assetName {
            source = .asset(name: assetName, bundle: .main)
        } else {
            source = .systemSymbol(
                name: agent.systemImageName ?? "person.crop.circle",
                accessibilityDescription: agent.displayName
            )
        }
        iconWidthConstraint.constant = 12
        iconToTitleConstraint.constant = 4
        iconView.apply(CmuxResolvedIconRequest(
            source: source,
            size: NSSize(width: 12, height: 12),
            tintColor: agent.assetName == nil ? .secondaryLabelColor : nil
        ))
    }
}
