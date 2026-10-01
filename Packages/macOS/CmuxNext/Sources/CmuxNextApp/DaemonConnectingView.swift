import AppKit
import CmuxNextDaemon
import CmuxNextDesign

/// Content of a window that has no workspace yet: "Connecting to cmux-tui"
/// while the first connection is in progress, then the failure once the
/// startup deadline passes. The window opens at launch with this view, so
/// the app is never windowless while the daemon is slow or unreachable.
final class DaemonConnectingView: NSView {
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var state: DaemonStartupState = .connecting

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        titleLabel.font = Typography.body
        titleLabel.alignment = .center
        detailLabel.font = Typography.caption
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 4
        detailLabel.isSelectable = true
        let stack = NSStackView(views: [spinner, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply(.connecting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme {
            titleLabel.textColor = Palette.textSecondary
            detailLabel.textColor = Palette.textSecondary
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
    }

    func apply(_ state: DaemonStartupState) {
        self.state = state
        switch state {
        case .connecting, .connected:
            titleLabel.stringValue = Strings.daemonConnecting
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
            spinner.startAnimation(nil)
        case .unavailable(let error):
            titleLabel.stringValue = Strings.daemonUnavailable
            detailLabel.stringValue = DaemonStartup.isPermanent(error)
                ? error.description
                : "\(error.description)\n\(Strings.daemonRetrying)"
            detailLabel.isHidden = false
            spinner.stopAnimation(nil)
        }
        setAccessibilityLabel([titleLabel.stringValue, detailLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    var titleText: String { titleLabel.stringValue }
}
