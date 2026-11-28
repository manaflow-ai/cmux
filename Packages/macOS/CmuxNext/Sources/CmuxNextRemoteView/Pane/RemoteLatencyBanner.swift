import AppKit
import CmuxNextDesign

/// "View only: high latency" under the toolbar, with "Control Anyway". The
/// picture stays visible: view mode works on a slow path.
final class RemoteLatencyBanner: NSView {
    var onControlAnyway: (() -> Void)?

    let surface = Glass.makeOverlayPanel(cornerRadius: 14)
    private let icon = RemoteChrome.symbol("exclamationmark.triangle.fill", size: 15)
    private let title = RemoteChrome.label(RemoteViewStrings.latencyTitle, size: 12.5, weight: .semibold)
    private let detail = RemoteChrome.label("", size: 11.5)
    private let button = RemoteChromeButton(title: RemoteViewStrings.controlAnyway)
    private let row: NSStackView

    override init(frame: NSRect) {
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        row = RemoteChrome.row([icon, text, button], spacing: 12, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 10))
        row.setCustomSpacing(18, after: text)
        super.init(frame: frame)
        surface.contentView.addSubview(row)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
            row.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor),
        ])
        button.onPress = { [weak self] in self?.onControlAnyway?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingContentSize: NSSize { row.fittingSize }

    override func layout() {
        super.layout()
        surface.frame = bounds
    }

    func update(state: RemotePaneState, colors: RemotePaneColors) {
        let rtt = state.status?.rttMs ?? 0
        let path = state.status.map { RemoteViewStrings.path($0.path) } ?? ""
        detail.stringValue = RemoteViewStrings.latencyDetail(rtt: rtt, path: path, limit: state.interactiveMaxRttMs)
        title.textColor = colors.textPrimary
        detail.textColor = colors.textSecondary
        icon.contentTintColor = colors.attention
        button.apply(text: colors.textPrimary, hover: colors.selectionFill, fill: colors.hoverFill)
    }
}
