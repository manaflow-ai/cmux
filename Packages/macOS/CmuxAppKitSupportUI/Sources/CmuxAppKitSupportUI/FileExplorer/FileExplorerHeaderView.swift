public import AppKit

/// Pure AppKit header bar for the file explorer: a leading folder (or
/// magnifying-glass) icon and a truncating path label.
///
/// In its normal state the icon is `folder.fill` and the label shows the
/// display path. When a quick-search query is active the icon switches to
/// `magnifyingglass` and the label shows `"/" + query`. The bar's fixed height
/// is injected as ``init(barHeight:)`` (the app passes its right-sidebar
/// secondary-bar metric) so the package owns no app-side chrome constants.
public final class FileExplorerHeaderView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let barHeight: CGFloat
    private var displayPath = ""
    private var quickSearchQuery: String?

    /// Creates the header bar pinned to a fixed `barHeight`.
    public init(barHeight: CGFloat) {
        self.barHeight = barHeight
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: barHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        applyHeaderState()
    }

    /// Updates the displayed path; a no-op when unchanged.
    public func update(displayPath: String) {
        guard self.displayPath != displayPath else { return }
        self.displayPath = displayPath
        applyHeaderState()
    }

    /// Updates the active quick-search query; a no-op when unchanged. A non-nil
    /// query switches the icon to a magnifying glass and the label to `/query`.
    public func updateQuickSearch(query: String?) {
        guard quickSearchQuery != query else { return }
        quickSearchQuery = query
        applyHeaderState()
    }

    private func applyHeaderState() {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        if let quickSearchQuery {
            iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            pathLabel.stringValue = "/" + quickSearchQuery
            pathLabel.toolTip = pathLabel.stringValue
        } else {
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            pathLabel.stringValue = displayPath
            pathLabel.toolTip = displayPath
        }
    }
}
