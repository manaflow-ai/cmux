public import AppKit
import CmuxNextDesign

/// What a `remote_view` tab shows instead of a desktop
/// (`RemoteViewTabPolicy`): why there is none, or, for a record no person
/// confirmed, a Connect button that starts nothing until it is pressed.
/// Every build has it, so a restored tab never opens as a blank web page.
///
///
/// One card, one alignment, leading: the machine's name (never an id) with its status as a chip at
/// the end of the same row, one line of text, then Connect as the theme's primary button (the
/// dialogs' default button, ``CmuxDialogButtonView``). The text wraps at the card's width, never past
/// its inset. Leo, 2026-11-16, on the old card: "is is a weirdly styled thing :(".
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
    private let status: RemoteStatusChip?
    private let button: CmuxDialogButtonView?
    private let surface = Glass.makeOverlayPanel(cornerRadius: 16)
    private var colors: RemotePaneColors?

    /// The card's width when the pane has room; a narrower pane narrows it and the text wraps.
    static let cardWidth: CGFloat = 420

    public init(content: Content) {
        self.content = content
        let text = Self.text(for: content)
        icon = RemoteChrome.symbol(text.symbol, size: TypeScale.title)
        title = RemoteChrome.label(text.title, size: TypeScale.title, weight: TypeScale.emphasis)
        detail = RemoteChrome.wrapping(text.detail, size: TypeScale.body, width: 0)
        status = text.status.map { RemoteStatusChip(text: $0, live: text.live) }
        switch content {
        case .confirm, .confirmTarget:
            button = CmuxDialogButtonView(CmuxDialogButton(id: "remote-connect", title: RemoteViewStrings.connect, role: .default),
                                          hint: nil, target: nil, action: #selector(RemoteViewUnavailableView.connectPressed))
        case .unavailable:
            button = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        button?.target = self
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        let column = arrange()
        surface.contentView.addSubview(column)
        let preferred = surface.widthAnchor.constraint(equalToConstant: Self.cardWidth)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            surface.centerYAnchor.constraint(equalTo: centerYAnchor),
            preferred,
            surface.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            surface.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            surface.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 20),
            surface.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            column.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor),
        ])
        setAccessibilityElement(button == nil)
        setAccessibilityRole(.group)
        setAccessibilityLabel([text.title, text.status, text.detail].compactMap { $0 }.joined(separator: ". "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Header row (icon, name, status chip at the end), the text at the row's width, then Connect.
    private func arrange() -> NSStackView {
        let inset = Metrics.space6 + Metrics.space4
        detail.alignment = .natural
        // The card's width decides where the text breaks, not the text's one-line width.
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let heading = stack([icon, title, spacer, status], vertical: false, spacing: Metrics.space4)
        heading.alignment = .centerY
        let column = stack([heading, detail, button], vertical: true, spacing: Metrics.space4)
        column.alignment = .leading
        column.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        column.setCustomSpacing(Metrics.space6, after: detail)
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * inset),
            detail.widthAnchor.constraint(equalTo: heading.widthAnchor),
        ])
        return column
    }

    private func stack(_ views: [NSView?], vertical: Bool, spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views.compactMap { $0 })
        stack.orientation = vertical ? .vertical : .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func connectPressed() { onConnect?() }

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
        status?.apply(next)
    }

    struct Text: Equatable {
        var symbol: String
        var title: String
        var detail: String
        /// The machine's status and region, drawn as a chip beside the title.
        var status: String?
        /// The status is a live one (running, starting): the chip's dot is the success color.
        var live = false
    }

    static func text(for content: Content) -> Text {
        let unavailable = "display.trianglebadge.exclamationmark"
        switch content {
        case let .confirm(host):
            return text(for: .confirmTarget(RemoteConnectionTarget(name: host)))
        case let .confirmTarget(target):
            return Text(symbol: target.kind == .desktop ? "display" : "network",
                        title: RemoteViewStrings.confirmTitle(target), detail: RemoteViewStrings.confirmDetail(target),
                        status: RemoteViewStrings.confirmStatus(target), live: target.isLive)
        case let .unavailable(reason):
            let detail = switch reason {
            case .notInThisBuild: RemoteViewStrings.unavailableNotInBuild
            case let .noTransport(host): RemoteViewStrings.unavailableNoTransport(host)
            case let .notLoopback(host): RemoteViewStrings.unavailableNotLoopback(host)
            case let .notPrivateNetwork(host): RemoteViewStrings.unavailableNotPrivateNetwork(host)
            case .remoteRecord: RemoteViewStrings.unavailableRemoteRecord
            case .invalidAddress: RemoteViewStrings.unavailableInvalidAddress
            }
            return Text(symbol: unavailable, title: RemoteViewStrings.unavailableTitle, detail: detail)
        }
    }
}

/// A machine's status as a chip: a dot (the success color while live, else tertiary) and the
/// status text on the theme's badge fill.
final class RemoteStatusChip: NSView {
    private let dot = NSView()
    private let label: ChromeLabel
    private let live: Bool

    init(text: String, live: Bool) {
        self.live = live
        label = RemoteChrome.label(text, size: TypeScale.caption, weight: TypeScale.emphasis)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        let size = Metrics.space3
        dot.layer?.cornerRadius = size / 2
        let row = RemoteChrome.row([dot, label], spacing: Metrics.space3,
                                   insets: NSEdgeInsets(top: Metrics.space1, left: Metrics.space4, bottom: Metrics.space1, right: Metrics.space4))
        addSubview(row)
        let height = TypeScale.captionLineHeight + Metrics.space1 * 2 + Metrics.space2
        layer?.cornerRadius = height / 2
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: size),
            dot.heightAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ colors: RemotePaneColors) {
        layer?.backgroundColor = colors.badgeFill.cgColor
        dot.layer?.backgroundColor = (live ? colors.success : colors.textTertiary).cgColor
        label.textColor = colors.textSecondary
    }
}
