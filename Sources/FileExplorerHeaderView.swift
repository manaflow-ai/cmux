import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Pure AppKit header bar with folder icon, path label, and hidden files toggle.
final class FileExplorerHeaderView: NSView {
    private let iconView = CmuxResolvedIconImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let trailingStack = NSStackView()
    private var heightConstraint: NSLayoutConstraint?
    private var pathAccessoryTrailingConstraint: NSLayoutConstraint?
    private var pathEdgeTrailingConstraint: NSLayoutConstraint?
    private var displayPath = ""
    private var quickSearchQuery: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        applyFonts()
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 4
        trailingStack.isHidden = true
        trailingStack.setHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(trailingStack)

        let heightConstraint = heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight)
        self.heightConstraint = heightConstraint
        let pathEdgeTrailingConstraint = pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        let pathAccessoryTrailingConstraint = pathLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingStack.leadingAnchor,
            constant: -6
        )
        self.pathEdgeTrailingConstraint = pathEdgeTrailingConstraint
        self.pathAccessoryTrailingConstraint = pathAccessoryTrailingConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathEdgeTrailingConstraint,

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            trailingStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),
        ])
        applyHeaderState()
    }

    func applyFonts() {
        pathLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        heightConstraint?.constant = RightSidebarChromeMetrics.secondaryBarHeight
    }

    func setTrailingAccessoryViews(_ views: [NSView]) {
        for view in trailingStack.arrangedSubviews {
            trailingStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            trailingStack.addArrangedSubview(view)
        }
        let hasAccessories = !views.isEmpty
        trailingStack.isHidden = !hasAccessories
        pathEdgeTrailingConstraint?.isActive = !hasAccessories
        pathAccessoryTrailingConstraint?.isActive = hasAccessories
    }

    func update(displayPath: String) {
        guard self.displayPath != displayPath else { return }
        self.displayPath = displayPath
        applyHeaderState()
    }

    func updateQuickSearch(query: String?) {
        guard quickSearchQuery != query else { return }
        quickSearchQuery = query
        applyHeaderState()
    }

    private func applyHeaderState() {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        if let quickSearchQuery {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "magnifyingglass", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: .secondaryLabelColor,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = "/" + quickSearchQuery
            pathLabel.toolTip = pathLabel.stringValue
        } else {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "folder.fill", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: .secondaryLabelColor,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = displayPath
            pathLabel.toolTip = displayPath
        }
    }
}
