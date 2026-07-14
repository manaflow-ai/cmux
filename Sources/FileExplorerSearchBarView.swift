import AppKit
import CmuxFoundation

/// Compact native chrome shared by filename filtering and full-text search.
@MainActor
final class FileExplorerSearchBarView: NSView {
    let searchField = FileExplorerSearchField()
    let statusLabel = NSTextField(labelWithString: "")

    var onScopeChanged: ((FileExplorerSearchScope) -> Void)?

    private let scopeMenu = NSMenu()
    private var searchHeightConstraint: NSLayoutConstraint!
    private(set) var scope: FileExplorerSearchScope = .names

    var preferredHeight: CGFloat {
        let baseHeight: CGFloat = scope == .contents ? 48 : 36
        return max(baseHeight, GlobalFontMagnification.scaled(baseHeight))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        configureLayout()
        applyFonts()
        apply(scope: .names, queryState: FileExplorerSearchQueryState())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(scope: FileExplorerSearchScope, queryState: FileExplorerSearchQueryState) {
        self.scope = scope
        let query = queryState.query(for: scope)
        if searchField.stringValue != query {
            searchField.stringValue = query
        }
        searchField.placeholderString = scope.placeholder
        for item in scopeMenu.items {
            item.state = item.tag == scope.rawValue ? .on : .off
        }
        if statusLabel.isHidden != (scope == .names) {
            statusLabel.isHidden = scope == .names
        }
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
        configureScopeMenu()

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

    private func configureScopeMenu() {
        for scope in FileExplorerSearchScope.allCases {
            let item = NSMenuItem(
                title: scope.title,
                action: #selector(scopeMenuItemPressed(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = scope.rawValue
            scopeMenu.addItem(item)
        }
        (searchField.cell as? NSSearchFieldCell)?.searchMenuTemplate = scopeMenu
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

    @objc private func scopeMenuItemPressed(_ sender: NSMenuItem) {
        guard let scope = FileExplorerSearchScope(rawValue: sender.tag) else { return }
        onScopeChanged?(scope)
    }
}
