import AppKit
import CmuxFoundation

final class FileExplorerSearchResultCellView: NSTableCellView {
    private let pathLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private var previewBelowPathConstraint: NSLayoutConstraint!
    private var previewAtTopConstraint: NSLayoutConstraint!

    static var preferredRowHeight: CGFloat {
        preferredRowHeight(startsFileGroup: true)
    }

    static func preferredRowHeight(startsFileGroup: Bool) -> CGFloat {
        if !startsFileGroup {
            return max(26, ceil(10 + lineHeight(for: GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .regular))))
        }
        return max(
            46,
            ceil(
                13 +
                    lineHeight(for: GlobalFontMagnification.systemFont(ofSize: 12, weight: .semibold)) +
                    lineHeight(for: GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .regular))
            )
        )
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        setAccessibilityElement(true)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1

        addSubview(pathLabel)
        addSubview(previewLabel)

        previewBelowPathConstraint = previewLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 2)
        previewAtTopConstraint = previewLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5)

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pathLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            previewLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: pathLabel.trailingAnchor),
            previewBelowPathConstraint,
        ])
    }

    func configure(with result: FileSearchResult, startsFileGroup: Bool) {
        pathLabel.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .semibold)
        previewLabel.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.isHidden = !startsFileGroup
        NSLayoutConstraint.deactivate([previewBelowPathConstraint, previewAtTopConstraint])
        (startsFileGroup ? previewBelowPathConstraint : previewAtTopConstraint).isActive = true
        pathLabel.stringValue = result.relativePath
        let preview = result.preview.isEmpty ? " " : result.preview
        previewLabel.stringValue = "\(result.lineNumber): \(preview)"
        let accessibilityFormat = String(
            localized: "fileExplorer.search.result.accessibilityLabel",
            defaultValue: "%@: line %lld"
        )
        setAccessibilityLabel(
            String.localizedStringWithFormat(
                accessibilityFormat,
                result.relativePath,
                Int64(result.lineNumber)
            )
        )
        setAccessibilityValue(result.preview)
        toolTip = "\(result.path):\(result.lineNumber):\(result.columnNumber)"
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
