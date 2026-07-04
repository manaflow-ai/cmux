import AppKit
import CmuxFoundation
import SwiftUI

final class FileExplorerSearchResultCellView: NSTableCellView {
    private let pathLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    static var preferredRowHeight: CGFloat {
        max(
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

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pathLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            previewLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: pathLabel.trailingAnchor),
            previewLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(with result: FileSearchResult, colorScheme: ColorScheme) {
        pathLabel.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .semibold)
        previewLabel.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .labelColor
        previewLabel.textColor = FileExplorerColors(colorScheme: colorScheme).secondaryTextColor
        pathLabel.stringValue = "\(result.relativePath):\(result.lineNumber)"
        previewLabel.stringValue = result.preview.isEmpty ? " " : result.preview
        toolTip = "\(result.path):\(result.lineNumber):\(result.columnNumber)"
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
