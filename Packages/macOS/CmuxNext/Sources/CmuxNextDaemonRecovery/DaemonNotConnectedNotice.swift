import AppKit
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign

/// "Not connected to cmux-tui" over a layout the window drew without the
/// daemon (the launch snapshot, a top page) once the startup deadline passed
/// (cx-jniyz.3), with the launch screen's Retry Now and Restart cmux-tui
/// (`DaemonRecoveryControls`). The layout stays visible behind it. It looks
/// like a terminal's status banner: the theme's raised surface, a hairline,
/// secondary text, no accent. Hidden while connecting, once connected, and
/// while the connecting screen shows the failure itself. It is an occluder of
/// the window's overlay host, so Chromium pages never cover it.
final class DaemonNotConnectedNotice: NSView {
    static let occluderID = "daemon.notConnected"
    private let label = NSTextField(labelWithString: "")
    private let controls: DaemonRecoveryControls

    init(recovery: DaemonRecovery) {
        controls = DaemonRecoveryControls(recovery: recovery)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = Metrics.lineWidth(1)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.orientation = .horizontal
        controls.alignment = .centerY
        let row = NSStackView(views: [label, controls])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("daemon.notConnected")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Floats in `host` at the bottom center of `anchor` (the window's content area).
    func install(in host: NSView, anchor: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: anchor.centerXAnchor),
            bottomAnchor.constraint(equalTo: anchor.bottomAnchor, constant: -Metrics.space4),
            widthAnchor.constraint(lessThanOrEqualTo: anchor.widthAnchor, constant: -2 * Metrics.space4),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme {
            layer?.backgroundColor = Palette.elevatedBackground.cgColor
            layer?.borderColor = Palette.separator.cgColor
            label.textColor = Palette.textSecondary
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window { WindowOverlayHost.existingHost(for: window)?.setOccluder(id: Self.occluderID, rect: nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        updateOccluder()
    }

    override func layout() {
        super.layout()
        updateOccluder()
    }

    /// Pages are masked under the notice while it shows.
    private func updateOccluder() {
        guard let window else { return }
        if isHidden {
            WindowOverlayHost.existingHost(for: window)?.setOccluder(id: Self.occluderID, rect: nil)
        } else {
            WindowOverlayHost.host(for: window).setOccluder(id: Self.occluderID, rect: convert(bounds, to: nil))
        }
    }

    /// Shows the failure while startup is unavailable and nothing else says so
    /// (`covered`: the connecting screen is on screen).
    func apply(_ startup: DaemonStartupState, covered: Bool) {
        if case .unavailable(let error) = startup, !covered {
            let text = [DaemonRecoveryStrings.notConnected, DaemonConnectingView.plainReason(error)].compactMap { $0 }.joined(separator: " · ")
            label.stringValue = text
            setAccessibilityLabel(text)
            controls.isOffered = true
            isHidden = false
        } else {
            controls.isOffered = false
            isHidden = true
        }
        updateOccluder()
    }
}
