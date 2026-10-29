package import AppKit
package import CmuxNextDesign

/// One Find result: the matching line, and the file and line number under it.
package final class FindResultCell: NSTableCellView {
    private let preview = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")

    package init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        preview.font = Typography.body
        preview.lineBreakMode = .byTruncatingTail
        location.font = Typography.caption
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        for view in [preview, location] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space2),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space1),
            location.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            location.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space2),
            location.topAnchor.constraint(equalTo: preview.bottomAnchor),
        ])
        textField = preview
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    package func show(_ match: RipgrepMatch) {
        preview.stringValue = match.preview
        location.stringValue = "\(match.relativePath):\(match.line)"
        setAccessibilityLabel("\(match.relativePath):\(match.line) \(match.preview)")
    }
}
