import AppKit
import CmuxNextDesign

/// The toolbar band in the window's top row, right of the traffic lights
/// (R68/R69, spec titlebar-area.md): the sidebar toggle first, at a fixed
/// frame that never moves with the sidebar (it lives in the window root,
/// not in the sidebar that animates), then the band's other items. A
/// strip under it starts its tabs after it (`TitlebarAccessoryHosting`).
final class TitlebarToolbarBand: NSView {
    let sidebarToggle = TitlebarBandButton(symbol: "sidebar.left")
    /// Runs the toggle's action (the registry's `toggleSidebar`).
    var onToggleSidebar: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggle)
        addSubview(sidebarToggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Every click toggles, mid-animation too: the button never moves, so
    /// there is no hit-test gap, and the sidebar's width animation
    /// retargets from what is on screen.
    @objc func toggle() { onToggleSidebar?() }

    /// The band's width for its items.
    static var width: CGFloat { TitlebarBandButton.side }

    override func layout() {
        super.layout()
        let side = TitlebarBandButton.side
        sidebarToggle.frame = NSRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
    }

    /// Names the toggle with its action title and bound key.
    func describeToggle(title: String, shortcut: String?) {
        sidebarToggle.setAccessibilityLabel(title)
        sidebarToggle.toolTip = shortcut.map { "\(title) (\($0))" } ?? title
    }
}

/// An icon button of the toolbar band: the chrome's hover and pressed look.
final class TitlebarBandButton: NSButton {
    static var side: CGFloat { Metrics.sidebarRowHeight - Metrics.space1 }
    private(set) lazy var hover = ChromeHover(self, behindContent: true)

    init(symbol: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .regular))
        contentTintColor = performWithTheme { Palette.textSecondary }
        _ = hover
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
}
