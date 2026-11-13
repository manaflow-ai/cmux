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
        /// Ask before connecting with human-facing machine metadata.
        case confirmTarget(RemoteConnectionTarget)
    }

    public let content: Content
    /// Connect pressed (confirm content only).
    public var onConnect: (() -> Void)?
    private let icon: NSImageView
    private let title: ChromeLabel
    private let detail: ChromeLabel
    private let button: RemoteChromeButton?
    private let column = NSStackView()
    private let surface = Glass.makeOverlayPanel(cornerRadius: 16)
    private var colors: RemotePaneColors?

    public init(content: Content) {
        self.content = content
        let text = Self.text(for: content)
        icon = RemoteChrome.symbol(text.symbol, size: 24)
        title = RemoteChrome.label(text.title, size: 18, weight: .semibold)
        detail = RemoteChrome.wrapping(text.detail, size: 13, width: 420)
        if case .confirm = content {
            button = RemoteChromeButton(title: RemoteViewStrings.connect)
        } else if case .confirmTarget = content {
            button = RemoteChromeButton(title: RemoteViewStrings.connect, symbol: "arrow.right", height: 32)
        } else {
            button = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        column.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSStackView(views: [icon, title])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10
        heading.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(heading)
        if let metadata = text.metadata {
            let status = RemoteChrome.label(metadata, size: 11.5, weight: .medium)
            status.textColor = ThemeTokens.unresolved.textSecondary.nsColor
            column.addArrangedSubview(status)
        }
        column.addArrangedSubview(detail)
        if let button {
            column.setCustomSpacing(8, after: detail)
            column.addArrangedSubview(button)
            button.onPress = { [weak self] in self?.onConnect?() }
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            surface.centerYAnchor.constraint(equalTo: centerYAnchor),
            surface.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            surface.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            surface.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            surface.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 20),
            surface.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            column.topAnchor.constraint(equalTo: surface.topAnchor),
            column.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
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
        surface.layer?.backgroundColor = next.background.withAlphaComponent(0.72).cgColor
        surface.layer?.borderColor = next.separator.withAlphaComponent(0.75).cgColor
        surface.layer?.borderWidth = next.drawsBorders ? 1 : 0
        icon.contentTintColor = next.textSecondary
        title.textColor = next.textPrimary
        detail.textColor = next.textSecondary
        button?.apply(text: next.litGlyph, hover: next.selectionFill, fill: next.accent)
    }

    struct Text: Equatable {
        var symbol: String
        var title: String
        var detail: String
        var metadata: String?
    }

    static func text(for content: Content) -> Text {
        let unavailable = "display.trianglebadge.exclamationmark"
        switch content {
        case let .confirm(host):
            return Text(symbol: "display", title: RemoteViewStrings.confirmTitle(host), detail: RemoteViewStrings.confirmDetail, metadata: nil)
        case let .confirmTarget(target):
            return Text(symbol: target.kind == .desktop ? "display" : "network",
                        title: RemoteViewStrings.confirmTitle(target), detail: RemoteViewStrings.confirmDetail(target),
                        metadata: RemoteViewStrings.confirmMetadata(target))
        case let .unavailable(reason):
            let detail = switch reason {
            case .notInThisBuild: RemoteViewStrings.unavailableNotInBuild
            case let .noTransport(host): RemoteViewStrings.unavailableNoTransport(host)
            case let .notLoopback(host): RemoteViewStrings.unavailableNotLoopback(host)
            case let .notPrivateNetwork(host): RemoteViewStrings.unavailableNotPrivateNetwork(host)
            case .remoteRecord: RemoteViewStrings.unavailableRemoteRecord
            case .invalidAddress: RemoteViewStrings.unavailableInvalidAddress
            }
            return Text(symbol: unavailable, title: RemoteViewStrings.unavailableTitle, detail: detail, metadata: nil)
        }
    }
}
