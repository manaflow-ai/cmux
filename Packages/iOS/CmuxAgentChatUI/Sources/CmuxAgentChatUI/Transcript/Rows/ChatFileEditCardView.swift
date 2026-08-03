import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native bounded unified-diff card.
@MainActor
public final class ChatFileEditCardView: UIControl {
    private static let collapsedLineCap = 8
    private let onShowDetail: @MainActor () -> Void

    public init(
        edit: ChatFileEdit,
        rowID: String,
        contentCache: ChatContentCache? = nil,
        onShowDetail: @escaping @MainActor () -> Void = {}
    ) {
        self.onShowDetail = onShowDetail
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.055, alpha: 1)
        layer.cornerRadius = 12
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        accessibilityIdentifier = "ChatFileEditDetail-\(rowID)"
        accessibilityLabel = Self.accessibilityLabel(edit)
        accessibilityHint = String(
            localized: "chat.detail.show.hint",
            defaultValue: "Opens a sheet with the full block content",
            bundle: .module
        )
        addTarget(self, action: #selector(showDetail), for: .primaryActionTriggered)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.isUserInteractionEnabled = false
        stack.addArrangedSubview(headerView(edit))
        if let diff = edit.unifiedDiff, !diff.isEmpty {
            let divider = UIView()
            divider.backgroundColor = .separator
            divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            stack.addArrangedSubview(divider)
            let lines = contentCache?.diffLines(messageID: rowID, diff: diff)
                ?? diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            stack.addArrangedSubview(diffView(lines: lines))
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func showDetail() {
        onShowDetail()
    }

    private func headerView(_ edit: ChatFileEdit) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: Self.operationSymbol(edit.operation)))
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let path = UILabel()
        path.text = edit.filePath
        path.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
        path.textColor = UIColor(white: 0.88, alpha: 1)
        path.lineBreakMode = .byTruncatingMiddle
        path.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [icon, path])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        if let additions = edit.additions {
            stack.addArrangedSubview(countLabel("+\(additions)", color: .systemGreen))
        }
        if let deletions = edit.deletions {
            stack.addArrangedSubview(countLabel("−\(deletions)", color: .systemRed))
        }
        let detail = UIImageView(image: UIImage(systemName: "doc.text.magnifyingglass"))
        detail.tintColor = .tertiaryLabel
        stack.addArrangedSubview(detail)

        let container = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        return container
    }

    private func diffView(lines: [String]) -> UIView {
        let visible = Array(lines.prefix(Self.collapsedLineCap))
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for line in visible {
            stack.addArrangedSubview(diffLine(line))
        }
        if lines.count > Self.collapsedLineCap {
            let more = String(
                localized: "chat.terminal.more_lines",
                defaultValue: "⋯ \(lines.count - Self.collapsedLineCap) more lines",
                bundle: .module
            )
            let label = countLabel(more, color: .secondaryLabel)
            label.directionalLayoutMargins = .init(top: 2, leading: 8, bottom: 2, trailing: 8)
            stack.addArrangedSubview(label)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
        return scroll
    }

    private func diffLine(_ line: String) -> UILabel {
        let label = UILabel()
        label.text = line.isEmpty ? " " : line
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.numberOfLines = 1
        label.textColor = Self.foregroundColor(line)
        label.backgroundColor = Self.backgroundColor(line)
        label.accessibilityLabel = Self.diffLineAccessibilityLabel(line)
        return label
    }

    private func countLabel(_ text: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = color
        label.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private static func operationSymbol(_ operation: ChatFileEdit.Operation) -> String {
        switch operation {
        case .edit: "pencil"
        case .write: "plus.square"
        case .delete: "trash"
        }
    }

    private static func operationLabel(_ operation: ChatFileEdit.Operation) -> String {
        switch operation {
        case .edit:
            String(localized: "chat.detail.operation.edit", defaultValue: "Edit", bundle: .module)
        case .write:
            String(localized: "chat.detail.operation.write", defaultValue: "Write", bundle: .module)
        case .delete:
            String(localized: "chat.detail.operation.delete", defaultValue: "Delete", bundle: .module)
        }
    }

    private static func accessibilityLabel(_ edit: ChatFileEdit) -> String {
        let title = String(
            localized: "chat.file_edit.accessibility",
            defaultValue: "File edit",
            bundle: .module
        )
        var parts = ["\(title): \(operationLabel(edit.operation)) \(edit.filePath)"]
        if let additions = edit.additions {
            let label = String(
                localized: "chat.file_edit.additions.accessibility",
                defaultValue: "additions",
                bundle: .module
            )
            parts.append("\(additions) \(label)")
        }
        if let deletions = edit.deletions {
            let label = String(
                localized: "chat.file_edit.deletions.accessibility",
                defaultValue: "deletions",
                bundle: .module
            )
            parts.append("\(deletions) \(label)")
        }
        return parts.joined(separator: ", ")
    }

    private static func diffLineAccessibilityLabel(_ line: String) -> String {
        if line.hasPrefix("+") {
            return String(
                localized: "chat.diff.added.accessibility",
                defaultValue: "Added: \(line.dropFirst())",
                bundle: .module
            )
        }
        if line.hasPrefix("-") {
            return String(
                localized: "chat.diff.removed.accessibility",
                defaultValue: "Removed: \(line.dropFirst())",
                bundle: .module
            )
        }
        if line.hasPrefix("@@") {
            return String(
                localized: "chat.diff.hunk.accessibility",
                defaultValue: "Section: \(line)",
                bundle: .module
            )
        }
        return line
    }

    private static func foregroundColor(_ line: String) -> UIColor {
        if line.hasPrefix("@@") { return UIColor(white: 0.88, alpha: 0.6) }
        if line.hasPrefix("+") { return .systemGreen }
        if line.hasPrefix("-") { return .systemRed }
        return UIColor(white: 0.88, alpha: 0.75)
    }

    private static func backgroundColor(_ line: String) -> UIColor {
        if line.hasPrefix("+") { return UIColor.systemGreen.withAlphaComponent(0.08) }
        if line.hasPrefix("-") { return UIColor.systemRed.withAlphaComponent(0.08) }
        return .clear
    }
}
#endif
