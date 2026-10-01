import AppKit
import CmuxNextDesign

/// Shown while the mux server does not answer: what to run, and Retry.
final class HomeUnavailableView: NSView {
    var onRetry: (() -> Void)?
    private let title = NSTextField(labelWithString: HomeStrings.unavailableTitle)
    private let detail = NSTextField(wrappingLabelWithString: HomeStrings.unavailableDetail)
    private let command = NSTextField(labelWithString: HomeLocation.startCommand)
    private lazy var retry = NSButton(title: HomeStrings.retry, target: self, action: #selector(retryPressed))

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Typography.bodyEmphasized
        detail.font = Typography.body
        detail.alignment = .center
        command.font = .monospacedSystemFont(ofSize: Typography.body.pointSize, weight: .regular)
        command.isSelectable = true
        [title, detail, command, retry].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        performWithTheme {
            title.textColor = Palette.textPrimary
            detail.textColor = Palette.textSecondary
            command.textColor = Palette.textPrimary
        }
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width - Metrics.space4 * 2, 420)
        var y = bounds.height * 0.35
        for view in [title, detail, command, retry] {
            let height = view === detail ? detail.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 200)).height ?? 40 : view.fittingSize.height
            let fit = view === detail ? width : min(width, view.fittingSize.width)
            view.frame = NSRect(x: (bounds.width - fit) / 2, y: y, width: fit, height: height)
            y += height + Metrics.space3
        }
    }

    @objc private func retryPressed() { onRetry?() }
}
