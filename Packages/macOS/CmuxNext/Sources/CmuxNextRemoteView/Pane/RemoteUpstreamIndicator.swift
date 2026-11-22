import AppKit
import CmuxNextDesign

/// The upstream media indicator (C4b consent contract): one row per kind
/// that holds consent, in the theme accent, each with a Stop control that
/// revokes at once. Always visible while a kind is active (never hover-only).
final class RemoteUpstreamIndicator: NSView {
    var onStop: ((RemoteUpstreamKind) -> Void)?

    let surface = Glass.makeOverlayPanel(cornerRadius: 15)
    private let row = RemoteChrome.row([], spacing: 8, insets: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 4))
    private var shown: [RemoteUpstreamKind] = []
    private var colors: RemotePaneColors?

    static let height: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        surface.contentView.addSubview(row)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: surface.contentView.centerYAnchor),
        ])
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingWidth: CGFloat { row.fittingSize.width }

    override func layout() {
        super.layout()
        surface.frame = bounds
    }

    func update(kinds: [RemoteUpstreamKind], colors: RemotePaneColors) {
        isHidden = kinds.isEmpty
        guard kinds != shown || colors != self.colors else { return }
        shown = kinds
        self.colors = colors
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, kind) in kinds.enumerated() {
            if index > 0 {
                let divider = RemoteChrome.divider()
                divider.layer?.backgroundColor = colors.separator.cgColor
                row.addArrangedSubview(divider)
            }
            let icon = RemoteChrome.symbol(RemoteUpstreamIndicator.symbol(kind), size: 12, weight: .semibold)
            icon.contentTintColor = colors.accent
            let label = RemoteChrome.label(RemoteViewStrings.sharing(kind), size: 12, weight: .medium)
            label.textColor = colors.textPrimary
            let stop = RemoteChromeButton(title: RemoteViewStrings.stop, height: 22)
            stop.apply(text: colors.accent, hover: colors.hoverFill)
            stop.setAccessibilityLabel(RemoteViewStrings.stopSharing(kind))
            stop.toolTip = RemoteViewStrings.stopSharing(kind)
            stop.onPress = { [weak self] in self?.onStop?(kind) }
            row.addArrangedSubview(icon)
            row.addArrangedSubview(label)
            row.addArrangedSubview(stop)
            row.setCustomSpacing(5, after: icon)
        }
        setAccessibilityLabel(kinds.map(RemoteViewStrings.sharing).joined(separator: ", "))
        needsLayout = true
    }

    /// The SF Symbol of a kind (toolbar buttons and indicator).
    static func symbol(_ kind: RemoteUpstreamKind) -> String {
        switch kind {
        case .microphone: "mic.fill"
        case .camera: "video.fill"
        case .screen: "rectangle.on.rectangle"
        }
    }
}
