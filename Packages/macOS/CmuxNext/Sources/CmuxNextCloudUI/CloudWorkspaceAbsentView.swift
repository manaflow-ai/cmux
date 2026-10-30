public import AppKit
public import CmuxNextDesign

/// A Cloud workspace that is not connected, in its window's content area (P-AUSTIN B7), in place of
/// a blank pane: why it is not connected (``CloudWorkspaceAbsence/message``) and the button that
/// brings it back, if any. Two presentations of the same state, chosen in Debug Settings while
/// Lawrence picks one: ``Style/card`` also names the workspace and its machine; ``Style/compact`` is
/// the reason in one line and the button.
public final class CloudWorkspaceAbsentView: NSView {
    public enum Style: Hashable, Sendable {
        /// The workspace's name, its machine, why it is not connected, and the button.
        case card
        /// Why it is not connected, in one line, and the button.
        case compact
    }

    public let style: Style
    /// The workspace and state shown now.
    public private(set) var workspaceID = ""
    public private(set) var absence = CloudWorkspaceAbsence.connecting
    private let perform: (CloudWorkspaceAbsence.Action) -> Void
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let machineLabel = ChromeLabel(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let button = ThemedDefaultButton()

    /// `perform` runs the button's action (sign in, resume the machine).
    public init(style: Style, perform: @escaping (CloudWorkspaceAbsence.Action) -> Void) {
        self.style = style
        self.perform = perform
        super.init(frame: .zero)
        titleLabel.font = Typography.title
        titleLabel.alignment = .center
        machineLabel.font = Typography.caption
        machineLabel.alignment = .center
        messageLabel.font = style == .card ? Typography.body : Typography.caption
        messageLabel.alignment = .center
        messageLabel.isSelectable = false
        messageLabel.maximumNumberOfLines = style == .card ? 4 : 1
        messageLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = style == .compact
        machineLabel.isHidden = style == .compact
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(buttonPressed)
        let stack = NSStackView(views: [titleLabel, machineLabel, messageLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = style == .card ? Metrics.space4 : Metrics.space2
        stack.setCustomSpacing(Metrics.space1, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space4),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.cloud.workspace.absent")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows workspace `workspaceID`, named `title`, on the machine named `machine`, in state `absence`.
    public func show(workspaceID: String, title: String, machine: String, absence: CloudWorkspaceAbsence) {
        self.workspaceID = workspaceID
        self.absence = absence
        titleLabel.stringValue = title
        machineLabel.stringValue = CloudWorkspaceAbsence.machineLine(machine)
        messageLabel.stringValue = absence.message
        button.title = absence.actionTitle ?? ""
        button.isHidden = absence.actionTitle == nil
        button.keyHint = absence.actionTitle == nil ? nil : .return
        setAccessibilityLabel([title, absence.message].joined(separator: ". "))
    }

    /// What the view shows now, for tests and captures: its title (empty in ``Style/compact``), message and button.
    public var shownText: (title: String, message: String, button: String?) {
        (titleLabel.isHidden ? "" : titleLabel.stringValue, messageLabel.stringValue, button.isHidden ? nil : button.title)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            machineLabel.textColor = Palette.textTertiary
            messageLabel.textColor = Palette.textSecondary
        }
    }

    @objc private func buttonPressed() {
        guard let action = absence.action else { return }
        perform(action)
    }
}
