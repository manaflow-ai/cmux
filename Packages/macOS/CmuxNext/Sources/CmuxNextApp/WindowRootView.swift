import AppKit
import CmuxNextDesign
import CmuxNextSidebar
import Observation

/// Window content: glass sidebar on the leading edge (traffic lights sit on
/// its top), a compact titlebar across the content column, and the
/// workspace layout below it. Terminal content is never under glass.
final class WindowRootView: NSView {
    let titlebar = TitlebarView()
    private let contentHost = NSView()
    private let sidebar: SidebarContainerView
    private var insetConstraints: [NSLayoutConstraint] = []
    private var bottomInset: NSLayoutConstraint?
    private var titleHeight: NSLayoutConstraint?
    private var tokenObservation: Task<Void, Never>?
    private(set) weak var content: NSView?

    init(sidebar: SidebarContainerView) {
        self.sidebar = sidebar
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        wantsLayer = true
        layer?.backgroundColor = Palette.windowBackground.cgColor
        for view in [contentHost, titlebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(sidebar)
        sidebar.sidebarView.titlebarHeightOverride = Metrics.titlebarHeight
        let inset = Metrics.panelInset
        let top = sidebar.topAnchor.constraint(equalTo: topAnchor, constant: inset)
        let leading = sidebar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
        let bottom = sidebar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        let titleHeight = titlebar.heightAnchor.constraint(equalToConstant: Metrics.titlebarHeight)
        let contentLeading = contentHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: inset)
        NSLayoutConstraint.activate([
            top, leading, bottom,
            titlebar.topAnchor.constraint(equalTo: topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleHeight,
            // Keep the title clear of the traffic lights when the sidebar hides.
            titlebar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.trafficLightInset),
            contentLeading,
            contentHost.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        insetConstraints = [top, leading, contentLeading]
        bottomInset = bottom
        self.titleHeight = titleHeight
        tokenObservation = Task { [weak self] in
            for await _ in Observations({ (Metrics.panelInset, Metrics.titlebarHeight) }) { self?.applyTokens() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        tokenObservation?.cancel()
    }

    private func applyTokens() {
        for constraint in insetConstraints { constraint.constant = Metrics.panelInset }
        bottomInset?.constant = -Metrics.panelInset
        titleHeight?.constant = Metrics.titlebarHeight
        sidebar.sidebarView.titlebarHeightOverride = Metrics.titlebarHeight
    }

    /// Replaces the workspace layout view.
    func show(_ view: NSView) {
        guard content !== view else { return }
        content?.removeFromSuperview()
        view.frame = contentHost.bounds
        view.autoresizingMask = [.width, .height]
        contentHost.addSubview(view)
        content = view
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.windowBackground.cgColor
        }
    }
}
