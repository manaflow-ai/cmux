import AppKit
import CmuxFileSearch
import CmuxFoundation
import UniformTypeIdentifiers

/// Row metrics shared by both result cell kinds. One fixed height keeps the
/// outline's row geometry O(1), which matters at 100k rows.
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

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let countLabel = FileSearchCountBadge()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
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
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
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
        iconView.image = Self.icon(forFileName: name)
        toolTip = file.path
        setAccessibilityLabel(String(
            format: String(localized: "fileSearch.fileRow.accessibility", defaultValue: "%@, %@"),
            file.relativePath,
            FileSearchStatusText.resultCount(file.matches.count)
        ))
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
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with node: FileSearchMatchNode) {
        let match = node.match
        previewLabel.attributedStringValue = Self.attributedPreview(for: match)
        toolTip = "\(node.file.relativePath):\(match.lineNumber):\(match.column)"
        setAccessibilityLabel(String(
            format: String(localized: "fileSearch.matchRow.accessibility", defaultValue: "Line %1$lld: %2$@"),
            Int64(match.lineNumber),
            match.preview
        ))
    }

    static func attributedPreview(for match: FileSearchMatch) -> NSAttributedString {
        let text = NSMutableAttributedString(string: match.preview, attributes: [
            .font: FileSearchResultMetrics.matchFont,
            .foregroundColor: NSColor.labelColor,
        ])
        let length = (match.preview as NSString).length
        let range = match.previewMatchRange
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        if upper > lower {
            text.addAttributes([
                .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.55),
                .foregroundColor: NSColor.black,
            ], range: NSRange(location: lower, length: upper - lower))
        }
        return text
    }
}
