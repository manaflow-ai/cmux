import AppKit

/// One reusable Files row: icon, name, git badge and an on-demand spinner.
///
/// Cells are recycled by `NSOutlineView`; `configure` only writes values that
/// changed so scrolling does not invalidate layout, and icons come from the
/// shared ``FileExplorerIconCache``.
final class FileExplorerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var loadingIndicator: NSProgressIndicator?
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)? {
        didSet {
            if (onHover == nil) != (oldValue == nil) { updateTrackingAreas() }
        }
    }
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconToTextConstraint: NSLayoutConstraint!
    private var badgeTrailingConstraint: NSLayoutConstraint!
    private(set) weak var node: FileExplorerNode?
    private var renderedIconKey: (style: FileExplorerStyle, appearance: NSAppearance.Name?, nodeKey: String)?
    private weak var iconCache: FileExplorerIconCache?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.animates = false
        imageView = iconView

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.cell?.usesSingleLineMode = true
        nameLabel.cell?.isScrollable = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = nameLabel

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.alignment = .right
        badgeLabel.maximumNumberOfLines = 1
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.isHidden = true

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(badgeLabel)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconToTextConstraint = nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4)
        badgeTrailingConstraint = badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,
            iconToTextConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeTrailingConstraint,
        ])
    }

    /// Applies a row's state. Writes are skipped when unchanged.
    func configure(
        with node: FileExplorerNode,
        gitStatus: GitFileStatus? = nil,
        style: FileExplorerStyle = .current,
        iconCache: FileExplorerIconCache? = nil
    ) {
        assert(Thread.isMainThread, "AppKit updates must run on the main thread")
        self.node = node
        self.iconCache = iconCache
        setIfChanged(nameLabel.stringValue, node.name) { nameLabel.stringValue = $0 }
        let font = style.nameFont
        if nameLabel.font != font { nameLabel.font = font }
        if iconWidthConstraint.constant != style.iconSize {
            iconWidthConstraint.constant = style.iconSize
            iconHeightConstraint.constant = style.iconSize
        }
        if iconToTextConstraint.constant != style.iconToTextSpacing {
            iconToTextConstraint.constant = style.iconToTextSpacing
        }
        applyIcon(for: node, style: style)
        applyLoading(node.isLoading)

        let textColor: NSColor
        let toolTip: String
        if let error = node.error {
            textColor = .systemRed
            toolTip = error
        } else if let gitStatus {
            textColor = style.gitColor(for: gitStatus)
            toolTip = node.path
        } else {
            textColor = .labelColor
            toolTip = node.path
        }
        if nameLabel.textColor != textColor { nameLabel.textColor = textColor }
        setIfChanged(nameLabel.toolTip, toolTip) { nameLabel.toolTip = $0 }
        applyBadge(node: node, gitStatus: gitStatus, style: style)
        setAccessibilityLabel(node.name)
    }

    private func applyIcon(for node: FileExplorerNode, style: FileExplorerStyle) {
        let appearanceName = effectiveAppearance.name
        let nodeKey = node.isDirectory ? node.path + "/" : node.path
        if let key = renderedIconKey, key.style == style, key.appearance == appearanceName, key.nodeKey == nodeKey {
            return
        }
        renderedIconKey = (style, appearanceName, nodeKey)
        let cache = iconCache ?? FileExplorerIconCache()
        iconView.image = cache.icon(for: node, style: style, appearance: effectiveAppearance)
    }

    private func applyLoading(_ isLoading: Bool) {
        if isLoading {
            let indicator = loadingIndicator ?? makeLoadingIndicator()
            if indicator.isHidden {
                indicator.isHidden = false
                indicator.startAnimation(nil)
            }
            badgeTrailingConstraint.constant = -22
        } else if let indicator = loadingIndicator, !indicator.isHidden {
            indicator.stopAnimation(nil)
            indicator.isHidden = true
            badgeTrailingConstraint.constant = -6
        }
    }

    private func makeLoadingIndicator() -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isHidden = true
        indicator.setAccessibilityIdentifier("FileExplorerLoadingIndicator")
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 12),
            indicator.heightAnchor.constraint(equalToConstant: 12),
        ])
        loadingIndicator = indicator
        return indicator
    }

    private func applyBadge(node: FileExplorerNode, gitStatus: GitFileStatus?, style: FileExplorerStyle) {
        var text = ""
        var color = NSColor.secondaryLabelColor
        var toolTip: String?
        if node.omittedCount > 0 {
            text = "+\(node.omittedCount)"
            toolTip = String(
                localized: "fileExplorer.omittedEntries",
                defaultValue: "This folder has more items than the remote listing returns."
            )
        } else if let gitStatus, !node.isDirectory {
            text = Self.badgeText(for: gitStatus)
            color = style.gitColor(for: gitStatus)
        } else if let gitStatus, node.isDirectory, gitStatus != .deleted {
            text = "•"
            color = style.gitColor(for: gitStatus)
        }
        let hidden = text.isEmpty
        if badgeLabel.isHidden != hidden { badgeLabel.isHidden = hidden }
        guard !hidden else { return }
        setIfChanged(badgeLabel.stringValue, text) { badgeLabel.stringValue = $0 }
        if badgeLabel.textColor != color { badgeLabel.textColor = color }
        let badgeFont = NSFont.monospacedSystemFont(ofSize: max(9, style.nameFont.pointSize - 2), weight: .semibold)
        if badgeLabel.font != badgeFont { badgeLabel.font = badgeFont }
        badgeLabel.toolTip = toolTip
    }

    private static func badgeText(for status: GitFileStatus) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        }
    }

    private func setIfChanged<Value: Equatable>(_ current: Value, _ next: Value, _ apply: (Value) -> Void) {
        if current != next { apply(next) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let node, let key = renderedIconKey else { return }
        renderedIconKey = nil
        applyIcon(for: node, style: key.style)
    }

    // MARK: Inline rename

    /// Turns the name into an editable field and selects the name stem, like Finder.
    func beginRenaming(delegate: NSTextFieldDelegate) -> Bool {
        guard let window else { return false }
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = .textBackgroundColor
        nameLabel.textColor = .textColor
        nameLabel.delegate = delegate
        nameLabel.lineBreakMode = .byClipping
        guard window.makeFirstResponder(nameLabel) else {
            endRenaming()
            return false
        }
        if let editor = nameLabel.currentEditor() {
            let name = nameLabel.stringValue as NSString
            let ext = name.pathExtension
            let stemLength = (node?.isDirectory == false && !ext.isEmpty && name.length > ext.count + 1)
                ? name.length - ext.count - 1
                : name.length
            editor.selectedRange = NSRange(location: 0, length: stemLength)
        }
        return true
    }

    func endRenaming() {
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.drawsBackground = false
        nameLabel.delegate = nil
        nameLabel.lineBreakMode = .byTruncatingMiddle
        if let node { nameLabel.stringValue = node.name }
    }

    var isRenaming: Bool { nameLabel.isEditable }

    // MARK: Hover prefetch

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        guard onHover != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}
