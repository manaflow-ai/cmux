import AppKit
import CmuxFoundation

/// The original Finder-style search chrome used by full-text search.
@MainActor
final class FileExplorerSearchBarView: NSView {
    let searchField = FileExplorerSearchField()
    let statusLabel = NSTextField(labelWithString: "")

    private var searchHeightConstraint: NSLayoutConstraint!

    var preferredHeight: CGFloat {
        let baseHeight: CGFloat = 48
        return max(baseHeight, GlobalFontMagnification.scaled(baseHeight))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        configureLayout()
        applyFonts()
        apply(query: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(query: String) {
        if searchField.stringValue != query {
            searchField.stringValue = query
        }
        searchField.placeholderString = String(
            localized: "fileExplorer.search.placeholder",
            defaultValue: "Search files"
        )
    }

    func applyFonts() {
        searchField.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .regular)
        statusLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        searchHeightConstraint?.constant = max(24, GlobalFontMagnification.scaled(24))
    }

    private func configureViews() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("FileExplorerSearchField")
        searchField.focusRingType = .none
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.cell?.lineBreakMode = .byClipping
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.alignment = .left
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(searchField)
        addSubview(statusLabel)
    }

    private func configureLayout() {
        searchHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            searchHeightConstraint,

            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 4),
            statusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
        ])
    }
}
