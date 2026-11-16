import AppKit
import CmuxNextDesign

/// The centered card over the pane: connecting, waiting for consent, and
/// the ended states (disconnected by a person, host stopped sharing,
/// connection lost, stopped, not allowed). Liquid Glass with the opaque
/// fallback under Reduce Transparency (`Glass.makeOverlayPanel`).
final class RemoteStateCard: NSView {
    var onReconnect: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    let surface = Glass.makeOverlayPanel(cornerRadius: Metrics.surfaceCornerRadius)
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
        let title = RemoteChrome.label(spec.title, size: 15, weight: .semibold)
        title.textColor = colors.textPrimary
        var views: [NSView] = [icon, title]
        if let text = spec.detail {
            let detail = RemoteChrome.wrapping(text, size: 12.5, width: 330)
            detail.textColor = colors.textSecondary
            views.append(detail)
        }
        if let note = spec.note {
            let label = RemoteChrome.wrapping(note, size: 11, width: 330)
            label.textColor = colors.attention
            views.append(label)
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
        case .reconnect, .signIn: onReconnect?()
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
        /// One line the title does not already say; nil when it says everything.
        var detail: String?
        var buttons: [ButtonKind]
        /// The phase-1 trust gap, shown where a connection is made.
        var note: String?
    }

    /// `viaCloudTunnel`: a Cloud desktop over the app's own tunnel, which the phase-1 trust gap
    /// (the development note) does not describe.
    /// `reconnecting`: an earlier session showed frames, so this connect is a reconnect (the last
    /// frame stays behind the card).
    /// The pane draws a connect in the Connect card's own frame (``RemoteViewUnavailableView``,
    /// `.connecting`), not this card; `.connecting` here is its words for tools and tests.
    /// No card narrates the path or the dial's steps: the title, the spinner and Cancel say it
    /// (Leo, 2026-11-16: "so many layout shifts with the bullshit display text in between").
    static func spec(for overlay: RemotePaneOverlay, host: String, viaCloudTunnel: Bool = false, reconnecting: Bool = false) -> Spec {
        switch overlay {
        case .connecting:
            return Spec(spinner: true, title: reconnecting ? RemoteViewStrings.reconnectingTitle(host) : RemoteViewStrings.connectingTitle(host),
                        detail: nil, buttons: [.cancel], note: viaCloudTunnel ? nil : RemoteViewStrings.developmentOnly)
        case .waitingForConsent:
            return Spec(symbol: "hand.raised", title: RemoteViewStrings.consentTitle(host),
                        detail: RemoteViewStrings.consentDetail(host), buttons: [.cancel],
                        note: RemoteViewStrings.developmentOnly)
        case let .ended(.disconnectedBy(name)):
            return Spec(symbol: "person.crop.circle.badge.xmark", title: RemoteViewStrings.kickedTitle(name),
                        detail: nil, buttons: [.reconnect, .close])
        case .ended(.hostStoppedSharing):
            return Spec(symbol: "rectangle.on.rectangle.slash", title: RemoteViewStrings.stoppedTitle,
                        detail: nil, buttons: [.reconnect, .close])
        case .ended(.stoppedByViewer):
            return Spec(symbol: "stop.circle", title: RemoteViewStrings.viewerStoppedTitle,
                        detail: nil, buttons: [.reconnect, .close])
        case .ended(.connectionLost):
            return Spec(symbol: "wifi.exclamationmark", symbolIsAttention: true, title: RemoteViewStrings.lostTitle,
                        detail: nil, buttons: [.reconnect, .close])
        case .ended(.consentDenied):
            return Spec(symbol: "hand.raised.slash", title: RemoteViewStrings.deniedTitle,
                        detail: RemoteViewStrings.deniedDetail(host), buttons: [.reconnect, .close])
        case let .ended(.signInRequired(rejected)):
            return Spec(symbol: "lock", symbolIsAttention: rejected, title: RemoteViewStrings.signInTitle(host),
                        detail: rejected ? RemoteViewStrings.signInRejectedDetail(host) : RemoteViewStrings.signInDetail(host),
                        buttons: [.signIn, .close])
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
