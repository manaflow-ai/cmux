import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native compact tool invocation row with status and detail affordance.
@MainActor
public final class ChatToolUseRowView: UIControl {
    private let onShowDetail: @MainActor () -> Void

    public init(
        toolUse: ChatToolUse,
        rowID: String,
        onShowDetail: @escaping @MainActor () -> Void = {}
    ) {
        self.onShowDetail = onShowDetail
        super.init(frame: .zero)

        let toolIcon = UIImageView(image: UIImage(systemName: Self.symbolName(for: toolUse.toolName)))
        toolIcon.preferredSymbolConfiguration = .init(textStyle: .caption1)
        toolIcon.tintColor = .secondaryLabel
        toolIcon.setContentHuggingPriority(.required, for: .horizontal)

        let summary = UILabel()
        summary.text = toolUse.summary
        summary.font = .preferredFont(forTextStyle: .footnote)
        summary.textColor = .secondaryLabel
        summary.lineBreakMode = .byTruncatingMiddle
        summary.numberOfLines = 1

        let status = Self.makeStatusView(toolUse.status)
        let detail = UIImageView(image: UIImage(systemName: "doc.text.magnifyingglass"))
        detail.preferredSymbolConfiguration = .init(textStyle: .caption2)
        detail.tintColor = .tertiaryLabel
        detail.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [toolIcon, summary, status, detail])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])

        accessibilityIdentifier = "ChatToolUseToggle-\(rowID)"
        accessibilityLabel = "\(toolUse.summary), \(Self.statusLabel(toolUse.status))"
        accessibilityHint = String(
            localized: "chat.detail.show.hint",
            defaultValue: "Opens a sheet with the full block content",
            bundle: .module
        )
        addTarget(self, action: #selector(showDetail), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func showDetail() {
        onShowDetail()
    }

    private static func makeStatusView(_ status: ChatToolUse.Status) -> UIView {
        switch status {
        case .running:
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
            indicator.startAnimating()
            indicator.accessibilityLabel = statusLabel(status)
            return indicator
        case .succeeded, .failed:
            let image = UIImageView(image: UIImage(systemName: status == .succeeded ? "checkmark" : "xmark"))
            image.preferredSymbolConfiguration = .init(pointSize: 11, weight: .semibold)
            image.tintColor = status == .succeeded ? .systemGreen : .systemRed
            image.accessibilityLabel = statusLabel(status)
            return image
        }
    }

    private static func statusLabel(_ status: ChatToolUse.Status) -> String {
        switch status {
        case .running:
            String(localized: "chat.tool.running.accessibility", defaultValue: "Running", bundle: .module)
        case .succeeded:
            String(localized: "chat.tool.succeeded.accessibility", defaultValue: "Succeeded", bundle: .module)
        case .failed:
            String(localized: "chat.tool.failed.accessibility", defaultValue: "Failed", bundle: .module)
        }
    }

    private static func symbolName(for toolName: String) -> String {
        let name = toolName.lowercased()
        if name == "read" { return "doc.text" }
        if name.contains("grep") || name.contains("glob") || name.contains("search") {
            return "magnifyingglass"
        }
        if name.contains("webfetch") || name.contains("websearch") { return "globe" }
        if name.contains("task") || name.contains("agent") { return "person.2" }
        return "gearshape"
    }
}
#endif
