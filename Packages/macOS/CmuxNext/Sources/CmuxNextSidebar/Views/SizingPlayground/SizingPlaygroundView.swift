public import AppKit
import CmuxNextDesign
import CmuxNextCompat
import CmuxNextDesignTokens

/// DEV and NIGHTLY (the Debug menu): the sizing playground (Lawrence msg 19857: every size
/// "proportional [to] the compactness of [the] ui ... cohesive, and derived"). One specimen per
/// `sidebar.density` and `sidebar.textSize` (``SizingPlaygroundCell``): a tab strip, sidebar rows,
/// the update card and its What's New popover, all from ``SidebarRowTokens``, so a surface that
/// does not follow the others shows at once. The bar switches Light and Dark, and the popover
/// between the derived sizes (what the app ships) and the sizes it had before (the pages' type under
/// the content zoom). The specimens re-draw live when the app's density or text tokens change.
public final class SizingPlaygroundView: NSView {
    private let appearanceControl = NSSegmentedControl()
    private let popoverControl = NSSegmentedControl()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var before = false
    private var tokenWatch: Task<Void, Never>?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearanceControl.segmentCount = 2
        appearanceControl.setLabel(Strings.sizingLight, forSegment: 0)
        appearanceControl.setLabel(Strings.sizingDark, forSegment: 1)
        appearanceControl.target = self
        appearanceControl.action = #selector(changeAppearance)
        popoverControl.segmentCount = 2
        popoverControl.setLabel(Strings.sizingDerived, forSegment: 0)
        popoverControl.setLabel(Strings.sizingBefore, forSegment: 1)
        popoverControl.selectedSegment = 0
        popoverControl.target = self
        popoverControl.action = #selector(changePopover)
        let bar = NSStackView(views: [appearanceControl, popoverControl])
        bar.spacing = Metrics.space6
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space4
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space4, left: Metrics.space6, bottom: Metrics.space6, right: Metrics.space6)
        let document = SizingPlaygroundDocument()
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        for view in [bar, scroll, stack, document] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(bar)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space6),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space6),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Metrics.space4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        rebuild()
        // The specimens follow the app's density, Interface Size and text tokens live.
        tokenWatch = Task { [weak self] in
            for await _ in ObservationStream({ SidebarRowTokens.current.base }) {
                guard let self else { return }
                self.rebuild()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The playground in its own window, wide enough for the widest popover beside a sidebar.
    public static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Strings.sizingWindowTitle
        window.contentView = SizingPlaygroundView(frame: .zero)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        appearanceControl.selectedSegment = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0
        layer?.backgroundColor = performWithTheme { Palette.chromeBackground.cgColor }
    }

    @objc private func changeAppearance() {
        window?.appearance = NSAppearance(named: appearanceControl.selectedSegment == 1 ? .darkAqua : .aqua)
        layer?.backgroundColor = performWithTheme { Palette.chromeBackground.cgColor }
        for view in stack.arrangedSubviews { view.needsDisplay = true }
    }

    @objc private func changePopover() {
        before = popoverControl.selectedSegment == 1
        rebuild()
    }

    /// One specimen per density and text size: its caption, then the specimen.
    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let base = SidebarRowTokens.current.base
        let zoom = DesignSettings.shared.uiScale
        for density in SidebarDensity.allCases {
            for size in SidebarTextSize.allCases {
                let cell = SizingPlaygroundCell(tokens: SidebarRowTokens(density: density, textSize: size, base: base), before: before, zoom: zoom)
                let caption = NSTextField(labelWithString: cell.caption)
                caption.font = Typography.caption
                caption.textColor = Palette.textSecondary
                stack.addArrangedSubview(caption)
                stack.addArrangedSubview(cell)
                stack.setCustomSpacing(Metrics.space2, after: caption)
                stack.setCustomSpacing(Metrics.space6 * 2, after: cell)
            }
        }
    }
}

/// The scroll view's document, top-down so the first specimen sits at the top.
private final class SizingPlaygroundDocument: NSView {
    override var isFlipped: Bool { true }
}
