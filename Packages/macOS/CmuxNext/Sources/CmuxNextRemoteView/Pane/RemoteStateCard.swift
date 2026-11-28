import AppKit
import CmuxNextDesign

/// The centered card over the pane: connecting, waiting for consent, and
/// the ended states (disconnected by a person, host stopped sharing,
/// stopped, not allowed). A lost path asks nothing: the pane reconnects by
/// itself (`RemoteDesktopPane.apply`), so its card has only Close. Liquid Glass with the opaque
/// fallback under Reduce Transparency (`Glass.makeOverlayPanel`).
final class RemoteStateCard: NSView {
    var onReconnect: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    let surface = Glass.makeOverlayPanel(cornerRadius: Metrics.surfaceCornerRadius, tone: .neutralGlass(.transient))
    private let column = NSStackView()
    private var content: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 20, right: 26)
        column.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(column)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
            column.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingContentSize: NSSize { column.fittingSize }

    override func layout() {
        super.layout()
        surface.frame = bounds
    }

    func configure(overlay: RemotePaneOverlay, host: String, viaCloudTunnel: Bool = false, reconnecting: Bool = false,
                   colors: RemotePaneColors) {
        for view in content { column.removeArrangedSubview(view); view.removeFromSuperview() }
        let spec = Self.spec(for: overlay, host: host, viaCloudTunnel: viaCloudTunnel, reconnecting: reconnecting)
        let icon: NSView = spec.spinner ? Self.spinner() : {
            let image = RemoteChrome.symbol(spec.symbol, size: 24)
            image.contentTintColor = spec.symbolIsAttention ? colors.attention : colors.textSecondary
            return image
        }()
        let label = RemoteChrome.label(spec.title, size: 15, weight: .semibold)
        label.textColor = colors.textPrimary
        // What the card would explain past its title shows on hover over an info circle beside it, never as lines
        // of caveats under it (Leo: "SCREEN SHARE IS SCREEN SHARE ... STOP PUTTING SO MANY DISCLAIMERS").
        let title: NSView = spec.info.map { info in
            let circle = RemoteChrome.symbol("info.circle", size: 13)
            circle.contentTintColor = colors.textSecondary
            circle.themedToolTip = info
            circle.setAccessibilityElement(true)
            circle.setAccessibilityRole(.image)
            circle.setAccessibilityLabel(info)
            circle.identifier = NSUserInterfaceItemIdentifier("remote.stateCard.info")
            return RemoteChrome.row([label, circle], spacing: 6, insets: NSEdgeInsets())
        } ?? label
        var views: [NSView] = [icon, title]
        if let text = spec.detail {
            let detail = RemoteChrome.wrapping(text, size: 12.5, width: 330)
            detail.textColor = colors.textSecondary
            views.append(detail)
        }
        let buttons = spec.buttons.map { kind -> RemoteChromeButton in
            let button = RemoteChromeButton(title: kind.title)
            button.apply(text: colors.textPrimary, hover: colors.selectionFill, fill: colors.hoverFill)
            button.onPress = { [weak self] in self?.press(kind) }
            return button
        }
        if !buttons.isEmpty { views.append(RemoteChrome.row(buttons, spacing: 8, insets: NSEdgeInsets())) }
        for view in views { column.addArrangedSubview(view) }
        column.setCustomSpacing(12, after: icon)
        column.setCustomSpacing(16, after: views[views.count - (buttons.isEmpty ? 1 : 2)])
        content = views
        setAccessibilityLabel(spec.title)
    }

    private func press(_ kind: ButtonKind) {
        switch kind {
        case .reconnect, .signIn: onReconnect?() // retry-prompt-ok: only the ends someone chose (see `spec`) and sign-in.
        case .cancel: onCancel?()
        case .close: onClose?()
        }
    }

    enum ButtonKind {
        case reconnect, signIn, cancel, close

        var title: String {
            switch self {
            case .reconnect: RemoteViewStrings.reconnect
            case .signIn: RemoteViewStrings.signIn
            case .cancel: RemoteViewStrings.cancel
            case .close: RemoteViewStrings.close
            }
        }
    }

    struct Spec {
        var symbol = "display"
        var symbolIsAttention = false
        var spinner = false
        var title: String
        /// One line the title does not already say and the person must read to act (a failure's reason, a
        /// rejected sign-in); nil when the title says everything.
        var detail: String?
        var buttons: [ButtonKind]
        /// What the person may want to know but need not read: on hover over the title's info circle (who must
        /// allow the session, the phase-1 trust gap where a connection is made).
        var info: String?
    }

    /// `viaCloudTunnel`: a Cloud desktop over the app's own tunnel, which the phase-1 trust gap
    /// (the development note, on the consent card) does not describe.
    /// `reconnecting`: an earlier session showed frames, so this connect is a reconnect (the last
    /// frame stays behind the card).
    /// The pane draws a connect in the Connect card's own frame (``RemoteViewUnavailableView``,
    /// `.connecting`), not this card; `.connecting` here is its words for tools and tests.
    /// No card narrates the path or the dial's steps: the title, the spinner and Cancel say it
    /// (Leo, 2026-11-16: "so many layout shifts with the [...] display text in between").
    static func spec(for overlay: RemotePaneOverlay, host: String, viaCloudTunnel: Bool = false, reconnecting: Bool = false) -> Spec {
        switch overlay {
        case .connecting:
            return Spec(spinner: true, title: reconnecting ? RemoteViewStrings.reconnectingTitle(host) : RemoteViewStrings.connectingTitle(host),
                        detail: nil, buttons: [.cancel])
        case .waitingForConsent:
            return Spec(symbol: "hand.raised", title: RemoteViewStrings.consentTitle(host), detail: nil, buttons: [.cancel],
                        info: [RemoteViewStrings.consentDetail(host), RemoteViewStrings.developmentOnly].joined(separator: "\n"))
        case let .ended(.disconnectedBy(name)):
            return Spec(symbol: "person.crop.circle.badge.xmark", title: RemoteViewStrings.kickedTitle(name),
                        // retry-prompt-ok: a person at the host ended this session on purpose; reconnecting overrides their choice.
                        detail: nil, buttons: [.reconnect, .close])
        case .ended(.hostStoppedSharing):
            return Spec(symbol: "rectangle.on.rectangle.slash", title: RemoteViewStrings.stoppedTitle,
                        // retry-prompt-ok: the host turned sharing off on purpose; reconnecting asks it again.
                        detail: nil, buttons: [.reconnect, .close])
        case let .ended(.hostFailed(reason)):
            return Spec(symbol: "exclamationmark.triangle", symbolIsAttention: true, title: RemoteViewStrings.hostFailedTitle,
                        // retry-prompt-ok: the host named a failure on that machine (capture, encoder, display); a retry
                        // fails the same way until someone fixes it there, so the press says "fixed, try now".
                        detail: RemoteViewStrings.hostFailedDetail(host, reason), buttons: [.reconnect, .close])
        case .ended(.stoppedByViewer):
            return Spec(symbol: "stop.circle", title: RemoteViewStrings.viewerStoppedTitle,
                        // retry-prompt-ok: the person pressed Stop; Reconnect is their choice to resume.
                        detail: nil, buttons: [.reconnect, .close])
        case .ended(.connectionLost):
            // The pane turns a lost path into a reconnect before it renders (`RemoteDesktopPane.apply`),
            // so no live pane shows this; it asks nothing anyway.
            return Spec(symbol: "wifi.exclamationmark", symbolIsAttention: true, title: RemoteViewStrings.lostTitle,
                        detail: nil, buttons: [.close])
        case .ended(.consentDenied):
            return Spec(symbol: "hand.raised.slash", title: RemoteViewStrings.deniedTitle, detail: nil,
                        // retry-prompt-ok: the host declined or did not answer; reconnecting prompts the person there again.
                        buttons: [.reconnect, .close], info: RemoteViewStrings.deniedDetail(host))
        case let .ended(.signInRequired(rejected)):
            return Spec(symbol: "lock", symbolIsAttention: rejected, title: RemoteViewStrings.signInTitle(host),
                        detail: rejected ? RemoteViewStrings.signInRejectedDetail(host) : nil,
                        buttons: [.signIn, .close], info: rejected ? nil : RemoteViewStrings.signInDetail(host))
        }
    }

    /// The themed spinner in the card's scope; it stills itself when loops are off (Reduce Motion).
    private static func spinner() -> NSView {
        let indicator = StatusIndicatorView.spinner()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 26),
            indicator.heightAnchor.constraint(equalToConstant: 26),
        ])
        indicator.spin(true)
        return indicator
    }
}
