import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native captured-terminal card with bounded output preview.
@MainActor
public final class ChatTerminalCardView: UIControl {
    private static let collapseThreshold = 6
    private static let collapsedHeadCount = 3
    private static let collapsedTailCount = 2
    private let onShowDetail: @MainActor () -> Void

    public init(
        capture: ChatTerminalCapture,
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
        accessibilityIdentifier = "ChatTerminalToggle-\(rowID)"
        accessibilityLabel = Self.accessibilityLabel(capture)
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
        stack.addArrangedSubview(headerView(capture))

        let lines = Self.outputLines(capture: capture, rowID: rowID, cache: contentCache)
        if !lines.isEmpty {
            let divider = UIView()
            divider.backgroundColor = .separator
            divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            stack.addArrangedSubview(divider)
            stack.addArrangedSubview(outputView(lines: lines))
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

    private func headerView(_ capture: ChatTerminalCapture) -> UIView {
        let prompt = UILabel()
        prompt.text = "$"
        prompt.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .semibold
        )
        prompt.textColor = .systemBlue
        prompt.setContentHuggingPriority(.required, for: .horizontal)

        let command = UILabel()
        command.text = capture.command
        command.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
        command.textColor = UIColor(white: 0.88, alpha: 1)
        command.lineBreakMode = .byTruncatingMiddle
        command.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [prompt, command])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        for status in statusViews(capture) {
            stack.addArrangedSubview(status)
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

    private func statusViews(_ capture: ChatTerminalCapture) -> [UIView] {
        if capture.isRunning {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
            indicator.startAnimating()
            return [indicator]
        }
        var views: [UIView] = []
        if let exitCode = capture.exitCode {
            let icon = UIImageView(image: UIImage(systemName: exitCode == 0 ? "checkmark" : "xmark"))
            icon.tintColor = exitCode == 0 ? .systemGreen : .systemRed
            views.append(icon)
            if exitCode != 0 {
                views.append(caption("\(exitCode)", color: .systemRed, monospaced: true))
            }
        }
        if let duration = capture.durationSeconds {
            views.append(caption(String(format: "%.1fs", duration), color: .secondaryLabel, monospaced: false))
        }
        return views
    }

    private func outputView(lines: [String]) -> UIView {
        let text: String
        if lines.count > Self.collapseThreshold {
            let hidden = lines.count - Self.collapsedHeadCount - Self.collapsedTailCount
            let more = String(
                localized: "chat.terminal.more_lines",
                defaultValue: "⋯ \(hidden) more lines",
                bundle: .module
            )
            text = Array(lines.prefix(Self.collapsedHeadCount)).joined(separator: "\n")
                + "\n\(more)\n"
                + Array(lines.suffix(Self.collapsedTailCount)).joined(separator: "\n")
        } else {
            text = lines.joined(separator: "\n")
        }
        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = UIColor(white: 0.88, alpha: 1)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            label.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -16),
        ])
        return scroll
    }

    private func caption(_ text: String, color: UIColor, monospaced: Bool) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = color
        let size = UIFont.preferredFont(forTextStyle: .caption2).pointSize
        label.font = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private static func outputLines(
        capture: ChatTerminalCapture,
        rowID: String,
        cache: ChatContentCache?
    ) -> [String] {
        guard let output = capture.output, !output.isEmpty else { return [] }
        if let cache {
            return cache.sanitizedLines(messageID: rowID, output: output)
        }
        let cleaned = ChatANSISanitizer().sanitized(output)
        return cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func accessibilityLabel(_ capture: ChatTerminalCapture) -> String {
        if capture.isRunning {
            return String(
                localized: "chat.terminal.running.accessibility",
                defaultValue: "Command \(capture.command), running",
                bundle: .module
            )
        }
        if let exitCode = capture.exitCode {
            if exitCode == 0 {
                return String(
                    localized: "chat.terminal.succeeded.accessibility",
                    defaultValue: "Command \(capture.command), succeeded",
                    bundle: .module
                )
            }
            return String(
                localized: "chat.terminal.failed.accessibility",
                defaultValue: "Command \(capture.command), failed, exit code \(exitCode)",
                bundle: .module
            )
        }
        return String(
            localized: "chat.terminal.command.accessibility",
            defaultValue: "Command \(capture.command)",
            bundle: .module
        )
    }
}
#endif
