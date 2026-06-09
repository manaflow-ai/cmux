import AppKit

// MARK: - Cell View

/// The reusable row view for a single file or folder in the explorer outline view.
///
/// Renders the type icon, name, an optional trailing git-status badge, and a loading
/// spinner, and supports inline name editing (used by create and rename). Cells are
/// recycled by `NSOutlineView`, so all per-row state is reset in ``configure(with:gitStatus:)``.
final class FileExplorerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)?
    private var nameLabelTrailingToLoadingConstraint: NSLayoutConstraint!
    private var nameLabelTrailingToContainerConstraint: NSLayoutConstraint!
    private var nameLabelTrailingToStatusConstraint: NSLayoutConstraint!

    /// Called with the field's text when an inline edit is committed (Enter or focus loss).
    var onCommitEdit: ((String) -> Void)?
    /// Called when an inline edit is cancelled (Escape).
    var onCancelEdit: (() -> Void)?
    private var isEditingName = false

    /// Creates a cell with the given reuse identifier and builds its subview hierarchy.
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconToTextConstraint: NSLayoutConstraint!
    private var loadingWidthConstraint: NSLayoutConstraint!

    /// Builds the icon / name / status / spinner subviews and their Auto Layout constraints.
    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byClipping
        statusLabel.maximumNumberOfLines = 1
        statusLabel.isHidden = true
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("FileExplorerStatusLabel")

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.setAccessibilityIdentifier("FileExplorerLoadingIndicator")

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(statusLabel)
        addSubview(loadingIndicator)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconToTextConstraint = nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4)
        loadingWidthConstraint = loadingIndicator.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            iconToTextConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingWidthConstraint,
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),

            statusLabel.trailingAnchor.constraint(equalTo: loadingIndicator.leadingAnchor, constant: -2),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        nameLabelTrailingToLoadingConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: loadingIndicator.leadingAnchor,
            constant: -2
        )
        nameLabelTrailingToContainerConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -2
        )
        nameLabelTrailingToStatusConstraint = nameLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: statusLabel.leadingAnchor,
            constant: -4
        )
        NSLayoutConstraint.activate([
            nameLabelTrailingToLoadingConstraint,
            nameLabelTrailingToContainerConstraint,
            nameLabelTrailingToStatusConstraint
        ])
        nameLabelTrailingToLoadingConstraint.isActive = false
        nameLabelTrailingToStatusConstraint.isActive = false
    }

    /// Populates the recycled cell for `node`, applying the current visual style, the type
    /// icon, the loading state, and the trailing git-status badge for `gitStatus` (if any).
    /// No-ops while the cell is mid inline-edit so the user's typing isn't clobbered.
    func configure(with node: FileExplorerNode, gitStatus: GitFileStatus? = nil) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        // Never overwrite the field while the user is typing a name into this reused cell.
        guard !isEditingName else { return }
        let style = FileExplorerStyle.current
        nameLabel.stringValue = node.name
        nameLabel.font = style.nameFont
        iconWidthConstraint.constant = style.iconSize
        iconHeightConstraint.constant = style.iconSize
        iconToTextConstraint.constant = style.iconToTextSpacing

        if style == .finder {
            if node.isDirectory {
                let folderIcon = NSWorkspace.shared.icon(for: .folder)
                folderIcon.size = NSSize(width: style.iconSize, height: style.iconSize)
                iconView.image = folderIcon
                iconView.contentTintColor = nil
            } else {
                let fileIcon = NSWorkspace.shared.icon(forFileType: (node.name as NSString).pathExtension)
                fileIcon.size = NSSize(width: style.iconSize, height: style.iconSize)
                iconView.image = fileIcon
                iconView.contentTintColor = nil
            }
        } else {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: style.iconSize, weight: style.iconWeight)
            if node.isDirectory {
                if style.hidesFolderGlyph {
                    // Chevron-only folders: the outline disclosure triangle conveys
                    // the folder, so the leading glyph collapses to zero width.
                    iconView.image = nil
                    iconView.contentTintColor = nil
                    iconWidthConstraint.constant = 0
                    iconToTextConstraint.constant = 0
                } else {
                    iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(symbolConfig)
                    iconView.contentTintColor = style.folderIconTint
                }
            } else if style.usesColorfulFileIcons {
                let fileIcon = FileExplorerFileIcon.resolve(for: node.name)
                iconView.image = NSImage(systemSymbolName: fileIcon.symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                    ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                iconView.contentTintColor = fileIcon.color
            } else {
                iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                iconView.contentTintColor = style.fileIconTint
            }
        }

        if node.isLoading {
            loadingWidthConstraint.constant = 12
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = true
            nameLabelTrailingToContainerConstraint.isActive = false
        } else {
            loadingWidthConstraint.constant = 0
            loadingIndicator.isHidden = true
            loadingIndicator.stopAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = false
            nameLabelTrailingToContainerConstraint.isActive = true
        }

        configureStatusBadge(for: node, gitStatus: gitStatus, style: style)

        if let error = node.error {
            nameLabel.textColor = .systemRed
            nameLabel.alphaValue = 1.0
            nameLabel.toolTip = error
        } else if let gitStatus {
            // For the colorful (Cursor-like) style, keep names neutral and use
            // dimming + the trailing badge to convey git state; other styles
            // continue to recolor the name text.
            if style.usesColorfulFileIcons {
                nameLabel.textColor = .labelColor
                nameLabel.alphaValue = gitStatus.dimsName ? 0.45 : 1.0
            } else {
                nameLabel.textColor = style.gitColor(for: gitStatus)
                nameLabel.alphaValue = 1.0
            }
            nameLabel.toolTip = node.path
        } else {
            nameLabel.textColor = .labelColor
            nameLabel.alphaValue = 1.0
            nameLabel.toolTip = node.path
        }
    }

    /// Shows or hides the trailing single-letter git status badge for the
    /// Cursor-like style. Directories and styles without badge support never
    /// show it; the badge is also suppressed while the row is loading so it
    /// does not collide with the spinner.
    private func configureStatusBadge(
        for node: FileExplorerNode, gitStatus: GitFileStatus?, style: FileExplorerStyle
    ) {
        let letter = (style.showsGitStatusLetter && !node.isDirectory && !node.isLoading)
            ? gitStatus?.statusLetter
            : nil
        if let letter, let gitStatus {
            statusLabel.stringValue = letter
            statusLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            statusLabel.textColor = style.gitColor(for: gitStatus)
            statusLabel.isHidden = false
            // The badge owns the name's trailing edge. Release the container/loading
            // trailing constraints so the three are mutually exclusive (no Auto Layout
            // conflict). The badge only appears when the row is not loading.
            nameLabelTrailingToContainerConstraint.isActive = false
            nameLabelTrailingToLoadingConstraint.isActive = false
            nameLabelTrailingToStatusConstraint.isActive = true
        } else {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            nameLabelTrailingToStatusConstraint.isActive = false
        }
    }

    /// Rebuilds the mouse-tracking area on resize so hover callbacks stay accurate.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Forwards hover-begin to ``onHover`` (used to prefetch a folder's children).
    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    /// Forwards hover-end to ``onHover``.
    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    // MARK: - Inline Name Editing

    /// Turns `nameLabel` into a focused, editable text field. When `selectingExtension`
    /// is false (files), only the name stem is selected so the extension is preserved;
    /// directories select the whole name.
    func beginEditing(selectingExtension: Bool) {
        guard let window else { return }
        isEditingName = true
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.isBordered = true
        nameLabel.bezelStyle = .squareBezel
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = .textBackgroundColor
        nameLabel.textColor = .labelColor
        nameLabel.focusRingType = .default
        nameLabel.delegate = self
        window.makeFirstResponder(nameLabel)
        guard let editor = nameLabel.currentEditor() else { return }
        let full = nameLabel.stringValue as NSString
        if selectingExtension {
            editor.selectedRange = NSRange(location: 0, length: full.length)
        } else {
            let stem = (nameLabel.stringValue as NSString).deletingPathExtension as NSString
            editor.selectedRange = NSRange(location: 0, length: stem.length)
        }
    }

    /// Restores the field to its non-editable label appearance.
    private func endEditingChrome() {
        isEditingName = false
        nameLabel.delegate = nil
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.focusRingType = .none
    }
}

extension FileExplorerCellView: NSTextFieldDelegate {
    /// Intercepts the field editor's commands during an inline edit; treats Escape as a cancel
    /// (firing ``onCancelEdit``) and lets all other commands fall through to commit.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isEditingName else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            let cancel = onCancelEdit
            endEditingChrome()
            cancel?()
            return true
        }
        return false
    }

    /// Commits the typed name (via ``onCommitEdit``) when the field editor ends on Enter, Tab,
    /// or focus loss — unless an Escape cancel already tore the edit down.
    func controlTextDidEndEditing(_ obj: Notification) {
        // `cancelOperation` already tore down editing and fired `onCancelEdit`; bail out so
        // Escape doesn't also commit. Enter, Tab, and focus loss all commit the typed value.
        guard isEditingName else { return }
        let value = nameLabel.stringValue
        let commit = onCommitEdit
        endEditingChrome()
        commit?(value)
    }
}
