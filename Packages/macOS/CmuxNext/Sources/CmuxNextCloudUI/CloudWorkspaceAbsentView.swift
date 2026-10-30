public import AppKit
public import CmuxNextDesign

/// A Cloud workspace that is not connected, in its window (P-AUSTIN B7): its name, why it is not
/// connected (``CloudWorkspaceAbsence/message``) and the button that brings it back, if any. Two
/// presentations of the same state, chosen in Debug Settings while Lawrence picks one:
/// ``Style/card`` fills the content area (centered), ``Style/banner`` is a bar over the top of the
/// workspace's last content.
public final class CloudWorkspaceAbsentView: NSView {
    public enum Style: Hashable, Sendable {
        /// Centered in the content area, in place of the workspace's content.
        case card
        /// A bar at the top of the workspace's last content, which stays under it.
        case banner
    }

    public let style: Style
    /// The workspace and state shown now.
    public private(set) var workspaceID = ""
    public private(set) var absence = CloudWorkspaceAbsence.connecting
    private let perform: (CloudWorkspaceAbsence.Action) -> Void
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let button = ThemedDefaultButton()

    /// The bar's height in the ``Style/banner`` style.
    public static let bannerHeight: CGFloat = 40

    /// `perform` runs the button's action (sign in, resume the machine).
    public init(style: Style, perform: @escaping (CloudWorkspaceAbsence.Action) -> Void) {
        self.style = style
        self.perform = perform
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.font = style == .card ? Typography.title : Typography.bodyEmphasized
        titleLabel.alignment = style == .card ? .center : .left
        messageLabel.font = Typography.body
        messageLabel.alignment = style == .card ? .center : .left
        messageLabel.isSelectable = false
        messageLabel.maximumNumberOfLines = style == .card ? 4 : 1
        messageLabel.lineBreakMode = .byTruncatingTail
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(buttonPressed)
        let stack = NSStackView(views: [titleLabel, messageLabel, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        if style == .banner {
            // A bar over content is glass, never a solid fill.
            let glass = GlassPanelView(style: .regular)
            glass.frame = bounds
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
        }
        addSubview(stack)
        switch style {
        case .card:
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = Metrics.space4
            stack.setCustomSpacing(Metrics.space2, after: titleLabel)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.space4),
                messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            ])
        case .banner:
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = Metrics.space3
            messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space4),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.space4),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.cloud.workspace.absent")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows workspace `workspaceID`, named `title`, in state `absence`.
    public func show(workspaceID: String, title: String, absence: CloudWorkspaceAbsence) {
        self.workspaceID = workspaceID
        self.absence = absence
        titleLabel.stringValue = title
        messageLabel.stringValue = absence.message
        button.title = absence.actionTitle ?? ""
        button.isHidden = absence.actionTitle == nil
        button.keyHint = absence.actionTitle == nil || style == .banner ? nil : .return
        setAccessibilityLabel([title, absence.message].joined(separator: ". "))
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
            messageLabel.textColor = Palette.textSecondary
        }
    }

    @objc private func buttonPressed() {
        guard let action = absence.action else { return }
        perform(action)
    }
}
