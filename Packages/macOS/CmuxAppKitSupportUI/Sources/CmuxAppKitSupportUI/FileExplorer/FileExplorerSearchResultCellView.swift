public import AppKit

/// Outline/table cell for one file-search result: a semibold middle-truncating
/// path label over a monospaced tail-truncating preview label.
///
/// The top label shows `"<relativePath>:<lineNumber>"`, the bottom label shows
/// the match preview (a single space when empty so the row keeps its height),
/// and the tooltip is `"<path>:<lineNumber>:<columnNumber>"`. The result fields
/// are injected through ``configure(relativePath:lineNumber:columnNumber:path:preview:)``
/// so the package owns no app-side search model type.
public final class FileExplorerSearchResultCellView: NSTableCellView {
    private let pathLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    /// Creates a cell registered under `identifier` for table-view reuse.
    public init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
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

    /// Populates the labels and tooltip from one search result's fields.
    public func configure(
        relativePath: String,
        lineNumber: Int,
        columnNumber: Int,
        path: String,
        preview: String
    ) {
        pathLabel.stringValue = "\(relativePath):\(lineNumber)"
        previewLabel.stringValue = preview.isEmpty ? " " : preview
        toolTip = "\(path):\(lineNumber):\(columnNumber)"
    }
}
