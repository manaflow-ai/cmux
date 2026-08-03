import AppKit
import CmuxFoundation

/// Hit rectangles for rendered tabs in the title bar's local coordinates.
struct CanvasTabHitRegions: Equatable {
    var tabFrames: [UUID: CGRect] = [:]
    var closeFrames: [UUID: CGRect] = [:]
}

/// Native title bar for a canvas pane.
@MainActor
final class CanvasPaneTitleBarView: NSView {
    static let height: CGFloat = 30

    private var chrome: CanvasPaneChrome
    private var barBackground: NSColor
    private var hoveredTabId: UUID?
    private var scrollOffset: CGFloat
    private var tabViews: [CanvasPaneTabView] = []
    var onHitRegionsChanged: (CanvasTabHitRegions) -> Void
    var onContentWidthChanged: (CGFloat) -> Void

    init(
        chrome: CanvasPaneChrome,
        barBackground: NSColor,
        hoveredTabId: UUID?,
        scrollOffset: CGFloat,
        onHitRegionsChanged: @escaping (CanvasTabHitRegions) -> Void,
        onContentWidthChanged: @escaping (CGFloat) -> Void
    ) {
        self.chrome = chrome
        self.barBackground = barBackground
        self.hoveredTabId = hoveredTabId
        self.scrollOffset = scrollOffset
        self.onHitRegionsChanged = onHitRegionsChanged
        self.onContentWidthChanged = onContentWidthChanged
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        rebuildTabs()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func update(
        chrome: CanvasPaneChrome,
        barBackground: NSColor,
        hoveredTabId: UUID?,
        scrollOffset: CGFloat
    ) {
        let tabIdentityChanged = chrome.tabs.map(\.id) != self.chrome.tabs.map(\.id)
        self.chrome = chrome
        self.barBackground = barBackground
        self.hoveredTabId = hoveredTabId
        self.scrollOffset = scrollOffset
        if tabIdentityChanged {
            rebuildTabs()
        } else {
            applyTabPresentations()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x = -scrollOffset
        var regions = CanvasTabHitRegions()
        for (index, tabView) in tabViews.enumerated() {
            let width = tabView.preferredWidth
            let frame = CGRect(x: x, y: 0, width: width, height: Self.height)
            tabView.frame = frame
            let tabID = chrome.tabs[index].id
            regions.tabFrames[tabID] = frame
            regions.closeFrames[tabID] = CGRect(
                x: frame.minX + 2,
                y: frame.minY,
                width: 22,
                height: Self.height
            )
            x += width
        }
        onContentWidthChanged(x + scrollOffset)
        onHitRegionsChanged(regions)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tabViews.forEach { $0.needsDisplay = true }
    }

    private func rebuildTabs() {
        tabViews.forEach { $0.removeFromSuperview() }
        tabViews = chrome.tabs.map { tab in
            let view = CanvasPaneTabView(tab: tab)
            addSubview(view)
            return view
        }
        applyTabPresentations()
        needsLayout = true
    }

    private func applyTabPresentations() {
        for (index, tabView) in tabViews.enumerated() where chrome.tabs.indices.contains(index) {
            let tab = chrome.tabs[index]
            tabView.update(
                tab: tab,
                isSelected: chrome.tabs.count == 1 || tab.id == chrome.selectedTabId,
                isHovered: tab.id == hoveredTabId,
                paneIsFocused: chrome.isFocused,
                barBackground: barBackground
            )
        }
    }
}

@MainActor
private final class CanvasPaneTabView: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var tab: CanvasTabChrome
    private var isSelected = false
    private var isHovered = false
    private var paneIsFocused = false
    private var barBackground = NSColor.windowBackgroundColor

    init(tab: CanvasTabChrome) {
        self.tab = tab
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat {
        let font = GlobalFontMagnification.systemFont(ofSize: 11)
        let titleWidth = (tab.title as NSString).size(withAttributes: [.font: font]).width
        return min(220, ceil(titleWidth + 32))
    }

    func update(
        tab: CanvasTabChrome,
        isSelected: Bool,
        isHovered: Bool,
        paneIsFocused: Bool,
        barBackground: NSColor
    ) {
        self.tab = tab
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.paneIsFocused = paneIsFocused
        self.barBackground = barBackground

        let textColor: NSColor = isSelected && paneIsFocused ? .labelColor : .secondaryLabelColor
        titleLabel.stringValue = tab.title
        titleLabel.font = GlobalFontMagnification.systemFont(ofSize: 11)
        titleLabel.textColor = textColor
        toolTip = tab.title
        setAccessibilityLabel(tab.title)
        setAccessibilitySelected(isSelected)

        let symbolName = isHovered ? "xmark" : tab.iconSystemName
        imageView.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        imageView.contentTintColor = isHovered ? .labelColor : textColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaled(isHovered ? 9 : 11),
            weight: isHovered ? .bold : .medium
        )
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        imageView.frame = CGRect(x: 6, y: 8, width: 14, height: 14)
        titleLabel.frame = CGRect(x: 26, y: 0, width: max(0, bounds.width - 33), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            barBackground.cmuxCanvasActiveTabFill.setFill()
            bounds.fill()
        } else if isHovered {
            barBackground.cmuxCanvasHoverTabFill.setFill()
            bounds.fill()
        }
        NSColor.separatorColor.setFill()
        CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}
