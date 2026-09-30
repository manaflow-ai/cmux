import AppKit
import CmuxFileSearch
import CmuxFoundation
import UniformTypeIdentifiers

/// Row metrics shared by both result cell kinds. One fixed height keeps the
/// table's row geometry O(1), which matters at 100k rows.
@MainActor
enum FileSearchResultMetrics {
    static var rowHeight: CGFloat { max(22, ceil(GlobalFontMagnification.scaled(22))) }
    static var fileNameFont: NSFont { GlobalFontMagnification.systemFont(ofSize: 12, weight: .medium) }
    static var directoryFont: NSFont { GlobalFontMagnification.systemFont(ofSize: 11) }
    static var matchFont: NSFont { GlobalFontMagnification.systemFont(ofSize: 12) }
    static var badgeFont: NSFont { GlobalFontMagnification.monospacedDigitSystemFont(ofSize: 10, weight: .semibold) }
}

/// A file row: type icon, file name, dimmed parent directory, match count.
@MainActor
final class FileSearchFileCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FileSearchFileCell")
    private static var iconCache: [String: NSImage] = [:]

    private let disclosureButton = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let countLabel = FileSearchCountBadge()
    /// The disclosure chevron was clicked.
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.refusesFirstResponder = true
        disclosureButton.target = self
        disclosureButton.action = #selector(toggle(_:))
        disclosureButton.contentTintColor = .secondaryLabelColor
        addSubview(disclosureButton)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        for label in [nameLabel, directoryLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
        }
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textColor = .labelColor
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        directoryLabel.lineBreakMode = .byTruncatingHead
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(directoryLabel)
        addSubview(countLabel)
        imageView = iconView
        textField = nameLabel
        NSLayoutConstraint.activate([
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 14),
            disclosureButton.heightAnchor.constraint(equalToConstant: 14),
            iconView.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            directoryLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            directoryLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: directoryLabel.trailingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with file: FileSearchFileNode) {
        let relative = file.relativePath as NSString
        let name = relative.lastPathComponent
        let directory = relative.deletingLastPathComponent
        nameLabel.font = FileSearchResultMetrics.fileNameFont
        directoryLabel.font = FileSearchResultMetrics.directoryFont
        if nameLabel.stringValue != name { nameLabel.stringValue = name }
        if directoryLabel.stringValue != directory { directoryLabel.stringValue = directory }
        countLabel.setCount(file.matches.count)
        let symbol = file.isExpanded ? "chevron.down" : "chevron.right"
        let label = file.isExpanded
            ? String(localized: "fileSearch.action.collapseFile", defaultValue: "Collapse")
            : String(localized: "fileSearch.action.expandFile", defaultValue: "Expand")
        disclosureButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        disclosureButton.setAccessibilityLabel(label)
        iconView.image = Self.icon(forFileName: name)
        toolTip = file.path
        setAccessibilityLabel(ListFormatter.localizedString(byJoining: [
            file.relativePath,
            FileSearchStatusText.resultCount(file.matches.count),
        ]))
    }

    @objc private func toggle(_ sender: Any?) {
        onToggle?()
    }

    /// File-type icons keyed by extension. Remote paths have no local file,
    /// so the icon never touches the filesystem.
    private static func icon(forFileName name: String) -> NSImage {
        let pathExtension = (name as NSString).pathExtension.lowercased()
        if let cached = iconCache[pathExtension] { return cached }
        let type = UTType(filenameExtension: pathExtension) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 16, height: 16)
        iconCache[pathExtension] = icon
        return icon
    }
}

/// The rounded match-count badge on a file row.
@MainActor
final class FileSearchCountBadge: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = 7
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCount(_ count: Int) {
        font = FileSearchResultMetrics.badgeFont
        let text = count.formatted()
        if stringValue != text { stringValue = text }
        textColor = .secondaryLabelColor
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(size.width + 10, 18), height: max(size.height + 1, 14))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}

/// A match row: the trimmed line with the match highlighted.
@MainActor
final class FileSearchMatchCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FileSearchMatchCell")

    private let previewLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.maximumNumberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.cell?.usesSingleLineMode = true
        previewLabel.allowsDefaultTighteningForTruncation = false
        addSubview(previewLabel)
        textField = previewLabel
        NSLayoutConstraint.activate([
            // Matches sit under their file's icon.
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with node: FileSearchMatchNode, accent: NSColor) {
        let match = node.match
        previewLabel.attributedStringValue = Self.attributedPreview(for: match, accent: accent)
        toolTip = "\(node.file.relativePath):\(match.lineNumber):\(match.column)"
        setAccessibilityLabel(String(
            format: String(localized: "fileSearch.matchRow.accessibility", defaultValue: "Line %1$@: %2$@"),
            String(match.lineNumber),
            match.preview
        ))
    }

    static func attributedPreview(for match: FileSearchMatch, accent: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: match.preview, attributes: [
            .font: FileSearchResultMetrics.matchFont,
            .foregroundColor: NSColor.labelColor,
        ])
        let length = (match.preview as NSString).length
        let range = match.previewMatchRange
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        if upper > lower {
            // The cmux accent (`app.accentColor`) marks the match.
            text.addAttributes([
                .backgroundColor: accent.withAlphaComponent(0.35),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: accent,
            ], range: NSRange(location: lower, length: upper - lower))
        }
        return text
    }
}
