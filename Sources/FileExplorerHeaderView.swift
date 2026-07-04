import AppKit
import CmuxFoundation
import SwiftUI

/// Pure AppKit header bar with folder icon, path label, and hidden files toggle.
final class FileExplorerHeaderView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint?
    private var displayPath = ""
    private var quickSearchQuery: String?
    private var colorScheme: ColorScheme = .light

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        let colors = FileExplorerColors(colorScheme: colorScheme)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = colors.secondaryIconTint

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        applyFonts()
        pathLabel.textColor = colors.secondaryTextColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(pathLabel)

        let heightConstraint = heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

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

    func applyFonts() {
        pathLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        heightConstraint?.constant = RightSidebarChromeMetrics.secondaryBarHeight
    }

    func updateColorScheme(_ nextColorScheme: ColorScheme, force: Bool = false) {
        guard force || colorScheme != nextColorScheme else { return }
        let colors = FileExplorerColors(colorScheme: nextColorScheme)
        colorScheme = nextColorScheme
        iconView.contentTintColor = colors.secondaryIconTint
        pathLabel.textColor = colors.secondaryTextColor
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
