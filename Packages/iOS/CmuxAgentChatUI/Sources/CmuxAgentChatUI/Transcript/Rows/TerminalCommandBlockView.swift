import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native single-column terminal command and output row.
@MainActor
public final class TerminalCommandBlockView: UIControl {
    private static let collapseThreshold = 12
    private static let collapsedHeadCount = 6
    private static let collapsedTailCount = 3
    private static let maxLineLength = 4_000

    private let onShowDetail: @MainActor () -> Void

    public init(
        block: TerminalCommandBlock,
        onOpenTerminal: @escaping @MainActor () -> Void,
        onShowDetail: @escaping @MainActor () -> Void = {}
    ) {
        self.onShowDetail = onShowDetail
        super.init(frame: .zero)
        accessibilityIdentifier = "TerminalCommandBlock-\(block.id)"

        if block.isInteractive {
            let card = TerminalInteractiveCardView(
                command: block.command,
                onOpenTerminal: onOpenTerminal
            )
            pin(card, leading: 0)
            isAccessibilityElement = false
            return
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 3
        stack.isUserInteractionEnabled = false
        stack.addArrangedSubview(commandLabel(block.command))
        let lines = Self.outputLines(block.output)
        if !lines.isEmpty {
            stack.addArrangedSubview(outputScrollView(lines: lines))
        }
        if let footer = footerView(block: block) {
            stack.addArrangedSubview(footer)
        }
        pin(stack, leading: 8)

        if block.failed {
            let rail = UIView()
            rail.backgroundColor = .systemRed
            rail.layer.cornerRadius = 1
            rail.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rail)
            NSLayoutConstraint.activate([
                rail.leadingAnchor.constraint(equalTo: leadingAnchor),
                rail.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                rail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
                rail.widthAnchor.constraint(equalToConstant: 2.5),
            ])
        }

        isAccessibilityElement = true
        accessibilityLabel = Self.accessibilityLabel(block)
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

    private func pin(_ view: UIView, leading: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    private func commandLabel(_ command: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )
        let text = NSMutableAttributedString(
            string: "❯ ",
            attributes: [.foregroundColor: UIColor.systemBlue, .font: font]
        )
        text.append(NSAttributedString(
            string: command.isEmpty ? " " : command,
            attributes: [.foregroundColor: UIColor(white: 0.88, alpha: 1), .font: font]
        ))
        label.attributedText = text
        return label
    }

    private func outputScrollView(lines: [String]) -> UIView {
        let display: String
        if lines.count > Self.collapseThreshold {
            let hidden = lines.count - Self.collapsedHeadCount - Self.collapsedTailCount
            let more = String(
                localized: "chat.terminal.more_lines",
                defaultValue: "⋯ \(hidden) more lines",
                bundle: .module
            )
            display = Array(lines.prefix(Self.collapsedHeadCount)).joined(separator: "\n")
                + "\n\(more)\n"
                + Array(lines.suffix(Self.collapsedTailCount)).joined(separator: "\n")
        } else {
            display = lines.joined(separator: "\n")
        }

        let label = UILabel()
        label.text = display
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = UIColor(white: 0.88, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            label.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return scroll
    }

    private func footerView(block: TerminalCommandBlock) -> UIView? {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        if block.isRunning {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
            indicator.startAnimating()
            stack.addArrangedSubview(indicator)
            stack.addArrangedSubview(label(
                String(localized: "chat.terminal.running", defaultValue: "running", bundle: .module),
                color: .secondaryLabel
            ))
            return stack
        }
        guard let exitCode = block.exitCode else { return nil }
        let image = UIImageView(image: UIImage(
            systemName: exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill"
        ))
        image.tintColor = exitCode == 0 ? .systemGreen : .systemRed
        stack.addArrangedSubview(image)
        if exitCode != 0 {
            stack.addArrangedSubview(label("exit \(exitCode)", color: .systemRed))
        }
        return stack
    }

    private func label(_ text: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        label.textColor = color
        return label
    }

    private static func outputLines(_ output: String) -> [String] {
        guard !output.isEmpty else { return [] }
        return output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "…" : String(line)
        }
    }

    private static func accessibilityLabel(_ block: TerminalCommandBlock) -> String {
        if block.isRunning {
            return String(
                localized: "chat.terminal.running.accessibility",
                defaultValue: "Command \(block.command), running",
                bundle: .module
            )
        }
        if let exitCode = block.exitCode, exitCode != 0 {
            return String(
                localized: "chat.terminal.failed.accessibility",
                defaultValue: "Command \(block.command), failed, exit code \(exitCode)",
                bundle: .module
            )
        }
        return String(
            localized: "chat.terminal.succeeded.accessibility",
            defaultValue: "Command \(block.command), succeeded",
            bundle: .module
        )
    }
}
#endif
