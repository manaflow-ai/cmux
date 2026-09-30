import AppKit
import CmuxNextDesign
import CmuxNextSidebar
import Observation

/// Window content: the sidebar flush on the leading edge (traffic lights sit
/// on its top), a compact titlebar across the content column, and the
/// workspace layout below it. Every surface is the terminal background
/// (`Palette.windowBackground`), so sidebar, titlebar, tab strip and
/// terminal read as one sheet with no panel edges or seams.
final class WindowRootView: NSView {
    let titlebar = TitlebarView()
    private let contentHost = NSView()
    private let sidebar: SidebarContainerView
    private var titleHeight: NSLayoutConstraint?
    private var tokenObservation: Task<Void, Never>?
    private(set) weak var content: NSView?

    init(sidebar: SidebarContainerView) {
        self.sidebar = sidebar
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        wantsLayer = true
        for view in [contentHost, titlebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(sidebar)
        sidebar.sidebarView.titlebarHeightOverride = Metrics.titlebarHeight
        let titleHeight = titlebar.heightAnchor.constraint(equalToConstant: Metrics.titlebarHeight)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            titlebar.topAnchor.constraint(equalTo: topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleHeight,
            // Keep the title clear of the traffic lights when the sidebar hides.
            titlebar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.trafficLightInset),
            contentHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.titleHeight = titleHeight
        tokenObservation = Task { [weak self] in
            for await _ in Observations({ Metrics.titlebarHeight }) { self?.applyTokens() }
        }
        themeDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        tokenObservation?.cancel()
    }

    private func applyTokens() {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeDidChange()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeDidChange()
    }

    /// Surface color plus window opacity: a translucent Ghostty background
    /// (`background-opacity`) makes the whole window translucent, like
    /// Ghostty.app, instead of compositing over an opaque backing.
    func themeDidChange() {
        let opaque = ThemeStore.shared.tokens.backgroundOpacity >= 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.windowBackground.cgColor
        }
        guard let window else { return }
        window.isOpaque = opaque
        window.backgroundColor = opaque ? Palette.windowBackground : .clear
    }
}
