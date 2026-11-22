public import AppKit
import CmuxNextDesign

/// What a `remote_view` tab shows instead of a desktop
/// (`RemoteViewTabPolicy`): why there is none, or, for a record no person
/// confirmed, a Connect button that starts nothing until it is pressed.
/// Every build has it, so a restored tab never opens as a blank web page.
///
///
/// One card, one alignment, leading: the machine's name (never an id) with its status as a chip at
/// the end of the same row, then Connect as the theme's primary button (the dialogs' default
/// button, ``CmuxDialogButtonView``). No sentence says how the tab opened or what Connect does
/// (Leo, 2026-11-16: "why even say all that? esp the second line."). An unavailable tab's
/// one line of text wraps at the card's width, never past its inset. Leo, 2026-11-16, on the old
/// card: "is is a weirdly styled thing :(".
///
/// `.connecting` is the same card in the same frame once Connect is pressed: the spinner takes the
/// icon's place and Cancel takes Connect's, so nothing moves until the first frame shows
/// (``RemoteDesktopPaneView`` draws it over the pane; Leo, 2026-11-16: "so many layout shifts").
public final class RemoteViewUnavailableView: NSView {
    public enum Content: Sendable, Hashable {
        case unavailable(RemoteViewUnavailableReason)
        /// Ask before connecting to `host`.
        case confirm(host: String)
        /// Ask before connecting with human-facing machine metadata.
        case confirmTarget(RemoteConnectionTarget)
        /// Connecting to the machine (`reconnecting`: again, over its last frame).
        case connecting(RemoteConnectionTarget, reconnecting: Bool)
    }

    public let content: Content
    /// Connect pressed (confirm content only).
    public var onConnect: (() -> Void)?
    /// Cancel pressed (connecting content only).
    var onCancel: (() -> Void)?
    private let icon: NSView
    private let title: ChromeLabel
    private let detail: ChromeLabel?
    private let status: RemoteStatusChip?
    private let button: CmuxDialogButtonView?
    private let surface = Glass.makeOverlayPanel(cornerRadius: 16)
    private var colors: RemotePaneColors?

    /// The card's width when the pane has room; a narrower pane narrows it and the text wraps.
    static let cardWidth: CGFloat = 420

    public init(content: Content) {
        self.content = content
        let text = Self.text(for: content)
        let symbol = RemoteChrome.symbol(text.symbol, size: TypeScale.title)
        icon = text.spinner ? Self.spinner(side: symbol.image?.size.height ?? TypeScale.titleLineHeight) : symbol
        title = RemoteChrome.label(text.title, size: TypeScale.title, weight: TypeScale.emphasis)
        detail = text.detail.map { RemoteChrome.wrapping($0, size: TypeScale.body, width: 0) }
        status = text.status.map { RemoteStatusChip(text: $0, live: text.live) }
        switch content {
        case .confirm, .confirmTarget:
            button = CmuxDialogButtonView(CmuxDialogButton(id: "remote-connect", title: RemoteViewStrings.connect, role: .default),
                                          hint: nil, target: nil, action: #selector(RemoteViewUnavailableView.connectPressed))
        case .connecting:
            button = CmuxDialogButtonView(CmuxDialogButton(id: "remote-cancel", title: RemoteViewStrings.cancel, role: .normal),
                                          hint: nil, target: nil, action: #selector(RemoteViewUnavailableView.cancelPressed))
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
        setAccessibilityLabel([text.spoken ?? text.title, text.status, text.detail].compactMap { $0 }.joined(separator: ". "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Header row (icon, name, status chip at the end), the text (if any) at the row's width, then the button.
    private func arrange() -> NSStackView {
        let inset = Metrics.space6 + Metrics.space4
        detail?.alignment = .natural
        // The card's width decides where the text breaks, not the text's one-line width.
        detail?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let heading = stack([icon, title, spacer, status], vertical: false, spacing: Metrics.space4)
        heading.alignment = .centerY
        let column = stack([heading, detail, button], vertical: true, spacing: Metrics.space4)
        column.alignment = .leading
        column.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        column.setCustomSpacing(Metrics.space6, after: (detail as NSView?) ?? heading)
        heading.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * inset).isActive = true
        detail?.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
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
    @objc private func cancelPressed() { onCancel?() }

    /// The themed spinner in a slot of the icon's size, so swapping one for the other moves nothing,
    /// also when the loading style hides the spinner itself.
    private static func spinner(side: CGFloat) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        let indicator = StatusIndicatorView.spinner()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(indicator)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: side),
            slot.heightAnchor.constraint(equalToConstant: side),
            indicator.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: slot.topAnchor),
            indicator.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
        ])
        indicator.spin(true)
        return slot
    }

    /// Connecting sits over the pane: it keeps no keyboard focus, and a click off the card reaches
    /// the desktop's capture view below, as it did before the card.
    public override var acceptsFirstResponder: Bool {
        if case .connecting = content { false } else { true }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard case .connecting = content else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return surface.frame.contains(local) ? super.hitTest(point) : nil
    }

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
        // Connecting draws over the pane, whose video view paints the same background (and a
        // reconnect's last frame).
        if case .connecting = content {} else { layer?.backgroundColor = next.background.cgColor }
        (icon as? NSImageView)?.contentTintColor = next.textSecondary
        title.textColor = next.textPrimary
        detail?.textColor = next.textSecondary
        status?.apply(next)
    }

    struct Text: Equatable {
        var symbol: String
        var title: String
        /// One line under the heading; nil for a machine's card, whose name and status say it.
        var detail: String?
        /// What VoiceOver reads in place of the title ("Connecting to …"); nil reads the title.
        var spoken: String?
        /// A spinner in the icon's place (connecting).
        var spinner = false
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
                        title: RemoteViewStrings.confirmTitle(target), detail: nil,
                        status: RemoteViewStrings.confirmStatus(target), live: target.isLive)
        case let .connecting(target, reconnecting):
            var text = text(for: .confirmTarget(target))
            let name = RemoteViewStrings.confirmTitle(target)
            text.spoken = reconnecting ? RemoteViewStrings.reconnectingTitle(name) : RemoteViewStrings.connectingTitle(name)
            text.spinner = true
            return text
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
