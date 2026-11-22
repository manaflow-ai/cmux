public import AppKit
import CmuxNextDesign

/// What a `remote_view` tab shows instead of a desktop
/// (`RemoteViewTabPolicy`): why there is none, or, for a record no person
/// confirmed, a Connect button that starts nothing until it is pressed.
/// Every build has it, so a restored tab never opens as a blank web page.
public final class RemoteViewUnavailableView: NSView {
    public enum Content: Sendable, Hashable {
        case unavailable(RemoteViewUnavailableReason)
        /// Ask before connecting to `host`.
        case confirm(host: String)
    }

    public let content: Content
    /// Connect pressed (confirm content only).
    public var onConnect: (() -> Void)?
    private let icon: NSImageView
    private let title: NSTextField
    private let detail: NSTextField
    private let button: RemoteChromeButton?
    private let column = NSStackView()
    private var colors: RemotePaneColors?

    public init(content: Content) {
        self.content = content
        let text = Self.text(for: content)
        icon = RemoteChrome.symbol(text.symbol, size: 24)
        title = RemoteChrome.label(text.title, size: 15, weight: .semibold)
        detail = RemoteChrome.wrapping(text.detail, size: 12.5, width: 360)
        if case .confirm = content {
            button = RemoteChromeButton(title: RemoteViewStrings.connect)
        } else {
            button = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, title, detail] { column.addArrangedSubview(view) }
        column.setCustomSpacing(12, after: icon)
        if let button {
            column.setCustomSpacing(16, after: detail)
            column.addArrangedSubview(button)
            button.onPress = { [weak self] in self?.onConnect?() }
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        setAccessibilityElement(button == nil)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text.title + ". " + text.detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
    }

    private func refreshColors() {
        let next = performWithTheme { RemotePaneColors.resolved() }
        guard next != colors else { return }
        colors = next
        layer?.backgroundColor = next.background.cgColor
        icon.contentTintColor = next.textSecondary
        title.textColor = next.textPrimary
        detail.textColor = next.textSecondary
        button?.apply(text: next.textPrimary, hover: next.selectionFill, fill: next.hoverFill)
    }

    struct Text: Equatable {
        var symbol: String
        var title: String
        var detail: String
    }

    static func text(for content: Content) -> Text {
        let unavailable = "display.trianglebadge.exclamationmark"
        switch content {
        case let .confirm(host):
            return Text(symbol: "display", title: RemoteViewStrings.confirmTitle(host), detail: RemoteViewStrings.confirmDetail)
        case let .unavailable(reason):
            let detail = switch reason {
            case .notInThisBuild: RemoteViewStrings.unavailableNotInBuild
            case let .noTransport(host): RemoteViewStrings.unavailableNoTransport(host)
            case let .notLoopback(host): RemoteViewStrings.unavailableNotLoopback(host)
            case .remoteRecord: RemoteViewStrings.unavailableRemoteRecord
            case .invalidAddress: RemoteViewStrings.unavailableInvalidAddress
            }
            return Text(symbol: unavailable, title: RemoteViewStrings.unavailableTitle, detail: detail)
        }
    }
}
