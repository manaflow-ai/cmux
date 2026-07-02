import AppKit

/// Files-style header bar for the Notes tab: folder icon plus the workspace
/// path (truncating-middle, secondary label — the `FileExplorerHeaderView`
/// treatment) with the tree's actions as trailing icon buttons, so the Notes
/// and Files tabs read identically.
final class NotesTreeHeaderView: NSView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let actionsStack = NSStackView()
    private weak var coordinator: NotesTreePanelView.Coordinator?

    init(coordinator: NotesTreePanelView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 2
        actionsStack.alignment = .centerY
        actionsStack.setContentHuggingPriority(.required, for: .horizontal)
        actionsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let buttons: [(String, String, Selector)] = [
            (
                "doc.badge.plus",
                String(localized: "notes.action.newNote", defaultValue: "New Note"),
                #selector(newNoteClicked)
            ),
            (
                "folder.badge.plus",
                String(localized: "notes.action.newFolder", defaultValue: "New Folder"),
                #selector(newFolderClicked)
            ),
            (
                "arrow.down.right.and.arrow.up.left",
                String(localized: "notes.action.collapseAll", defaultValue: "Collapse All"),
                #selector(collapseAllClicked)
            ),
            (
                "arrow.clockwise",
                String(localized: "notes.action.refresh", defaultValue: "Refresh"),
                #selector(refreshClicked)
            ),
        ]
        for (symbol, tooltip, action) in buttons {
            actionsStack.addArrangedSubview(actionButton(symbol: symbol, tooltip: tooltip, action: action))
        }

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(actionsStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionsStack.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 6),
            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func actionButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        return button
    }

    func update(displayPath: String, toolTip: String?) {
        pathLabel.stringValue = displayPath
        pathLabel.toolTip = toolTip ?? displayPath
    }

    @objc private func newNoteClicked() { coordinator?.newNote(inFolder: nil) }
    @objc private func newFolderClicked() { coordinator?.newFolder(inFolder: nil) }
    @objc private func collapseAllClicked() { coordinator?.collapseAll() }
    @objc private func refreshClicked() { coordinator?.refresh() }
}
