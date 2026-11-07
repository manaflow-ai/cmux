public import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): the tab bar playground (Debug menu > Tab Bar Playground): live galleries of tab bar
/// designs, each row the real tab strip with real hover, clicks, closes and new tabs.
///
/// Pages: Crowded Tabs (Lawrence msg 19596), New Tab Control (msg 19605, the "+ ⌄") and Trailing
/// Controls (msg 19627, the two ⋮). The bar on top switches the page, the appearance (Light, Dark)
/// and the tab count (10, 26, 50) live; the window resizes every row, so a narrow pane is a drag
/// away. A row marked "Shipped" is what the app has now.
public final class TabBarPlaygroundView: NSView {
    private let sections = NSSegmentedControl()
    private let appearanceControl = NSSegmentedControl()
    private let counts = NSSegmentedControl()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private static let tabCounts = [10, 26, 50]
    private var section = TabBarPlaygroundSection.crowdedTabs
    private var tabCount = 26

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sections.segmentCount = TabBarPlaygroundSection.allCases.count
        for (index, page) in TabBarPlaygroundSection.allCases.enumerated() { sections.setLabel(page.title, forSegment: index) }
        sections.selectedSegment = section.rawValue
        sections.target = self
        sections.action = #selector(changeSection)
        appearanceControl.segmentCount = 2
        appearanceControl.setLabel(Strings.playgroundLight, forSegment: 0)
        appearanceControl.setLabel(Strings.playgroundDark, forSegment: 1)
        appearanceControl.target = self
        appearanceControl.action = #selector(changeAppearance)
        counts.segmentCount = Self.tabCounts.count
        for (index, count) in Self.tabCounts.enumerated() { counts.setLabel(Strings.playgroundTabCount(count), forSegment: index) }
        counts.selectedSegment = Self.tabCounts.firstIndex(of: tabCount) ?? 0
        counts.target = self
        counts.action = #selector(changeCount)
        let bar = NSStackView(views: [sections, appearanceControl, counts])
        bar.spacing = Metrics.space6
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space4
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space4, left: Metrics.space6, bottom: Metrics.space6, right: Metrics.space6)
        let document = FlippedDocumentView()
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
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
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The playground in its own window, sized for a wide pane.
    public static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 860),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = Strings.playgroundWindowTitle
        window.contentView = TabBarPlaygroundView(frame: .zero)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        appearanceControl.selectedSegment = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0
        layer?.backgroundColor = performWithTheme { Palette.chromeBackground.cgColor }
    }

    @objc private func changeSection() {
        section = TabBarPlaygroundSection(rawValue: sections.selectedSegment) ?? .crowdedTabs
        rebuild()
    }

    @objc private func changeCount() {
        tabCount = Self.tabCounts[max(0, counts.selectedSegment)]
        rebuild()
    }

    @objc private func changeAppearance() {
        window?.appearance = NSAppearance(named: appearanceControl.selectedSegment == 1 ? .darkAqua : .aqua)
        layer?.backgroundColor = performWithTheme { Palette.chromeBackground.cgColor }
    }

    /// One row per variant of the page: its caption, then its live bar at the full width.
    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for variant in section.variants {
            let caption = NSTextField(labelWithString: variant.isShipped ? Strings.playgroundShipped(variant.name) : variant.name)
            caption.font = Typography.caption
            caption.textColor = Palette.textSecondary
            let content = variant.make(tabCount)
            content.translatesAutoresizingMaskIntoConstraints = false
            let height = content is TabBarPlaygroundTrailingRows ? TabBarPlaygroundTrailingRows.preferredHeight
                : content is ConcentricCornerPlaygroundRow ? ConcentricCornerPlaygroundRow.preferredHeight : TabStripView.preferredHeight
            stack.addArrangedSubview(caption)
            stack.addArrangedSubview(content)
            NSLayoutConstraint.activate([
                content.heightAnchor.constraint(equalToConstant: height),
                content.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Metrics.space6),
            ])
            stack.setCustomSpacing(Metrics.space2, after: caption)
        }
    }
}

/// The scroll view's document, top-down so the first variant sits at the top.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
