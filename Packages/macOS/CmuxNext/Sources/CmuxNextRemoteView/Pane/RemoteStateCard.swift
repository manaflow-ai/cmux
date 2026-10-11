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

    let surface = Glass.makeOverlayPanel(cornerRadius: 16)
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

    func configure(overlay: RemotePaneOverlay, host: String, colors: RemotePaneColors) {
        for view in content { column.removeArrangedSubview(view); view.removeFromSuperview() }
        let spec = Self.spec(for: overlay, host: host)
        let icon: NSView = spec.spinner ? Self.spinner(colors: colors) : {
            let image = RemoteChrome.symbol(spec.symbol, size: 24)
            image.contentTintColor = spec.symbolIsAttention ? colors.attention : colors.textSecondary
            return image
        }()
        let title = RemoteChrome.label(spec.title, size: 15, weight: .semibold)
        title.textColor = colors.textPrimary
        let detail = RemoteChrome.wrapping(spec.detail, size: 12.5, width: 330)
        detail.textColor = colors.textSecondary
        var views: [NSView] = [icon, title, detail]
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
        case .reconnect: onReconnect?()
        case .cancel: onCancel?()
        case .close: onClose?()
        }
    }

    enum ButtonKind {
        case reconnect, cancel, close

        var title: String {
            switch self {
            case .reconnect: RemoteViewStrings.reconnect
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
        var detail: String
        var buttons: [ButtonKind]
        /// The phase-1 trust gap, shown where a connection is made.
        var note: String?
    }

    static func spec(for overlay: RemotePaneOverlay, host: String) -> Spec {
        switch overlay {
        case .connecting:
            return Spec(spinner: true, title: RemoteViewStrings.connectingTitle(host),
                        detail: RemoteViewStrings.connectingDetail, buttons: [.cancel],
                        note: RemoteViewStrings.developmentOnly)
        case .waitingForConsent:
            return Spec(symbol: "hand.raised", title: RemoteViewStrings.consentTitle(host),
                        detail: RemoteViewStrings.consentDetail(host), buttons: [.cancel],
                        note: RemoteViewStrings.developmentOnly)
        case let .ended(.disconnectedBy(name)):
            return Spec(symbol: "person.crop.circle.badge.xmark", title: RemoteViewStrings.kickedTitle(name),
                        detail: RemoteViewStrings.kickedDetail(name, host), buttons: [.reconnect, .close])
        case .ended(.hostStoppedSharing):
            return Spec(symbol: "rectangle.on.rectangle.slash", title: RemoteViewStrings.stoppedTitle,
                        detail: RemoteViewStrings.stoppedDetail(host), buttons: [.reconnect, .close])
        case .ended(.stoppedByViewer):
            return Spec(symbol: "stop.circle", title: RemoteViewStrings.viewerStoppedTitle,
                        detail: RemoteViewStrings.viewerStoppedDetail, buttons: [.reconnect, .close])
        case .ended(.connectionLost):
            return Spec(symbol: "wifi.exclamationmark", symbolIsAttention: true, title: RemoteViewStrings.lostTitle,
                        detail: RemoteViewStrings.lostDetail(host), buttons: [.reconnect, .close])
        case .ended(.consentDenied):
            return Spec(symbol: "hand.raised.slash", title: RemoteViewStrings.deniedTitle,
                        detail: RemoteViewStrings.deniedDetail(host), buttons: [.reconnect, .close])
        }
    }

    /// A spinner, or a still glyph when loops are off (Reduce Motion).
    private static func spinner(colors: RemotePaneColors) -> NSView {
        guard Motion.animatesLoops else {
            let image = RemoteChrome.symbol("ellipsis.circle", size: 24)
            image.contentTintColor = colors.textSecondary
            return image
        }
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.isIndeterminate = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 26),
            indicator.heightAnchor.constraint(equalToConstant: 26),
        ])
        indicator.startAnimation(nil)
        return indicator
    }
}
