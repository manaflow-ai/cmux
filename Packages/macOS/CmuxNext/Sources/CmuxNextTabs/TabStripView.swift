public import AppKit
import CmuxNextDesign
import Observation
import QuartzCore

/// Chrome-style tab strip for one pane.
///
/// Reads a `TabStripModel`, lays tabs out with `TabLayoutEngine`, and animates
/// between layouts with per-tab springs on a display link, so open, close,
/// reorder, and scroll all retarget smoothly mid-flight. All user actions go
/// out as `TabStripIntent`s through `model.send`; the strip never edits the
/// model itself.
public final class TabStripView: NSView {
    public enum Background: Sendable {
        case none
        /// One Liquid Glass panel behind all tabs.
        case glass
    }

    /// Height the strip is designed for (density token).
    public static var preferredHeight: CGFloat { Metrics.tabStripHeight }

    public let model: TabStripModel

    public weak var previewProvider: (any TabPreviewProvider)? {
        didSet { hoverCard.previewProvider = previewProvider }
    }

    /// Fixed metrics instead of the live design tokens. Nil (the default)
    /// follows `DesignSettings.shared`: density and per-metric overrides
    /// apply live, with a relayout and re-measured titles.
    public var customMetrics: TabStripMetrics? {
        didSet { applyTokens(animated: false) }
    }

    /// Metrics in effect. Re-read from the tokens on every settings change.
    public private(set) var metrics: TabStripMetrics = .standard

    public var hoverCardPolicy: HoverCardPolicy {
        get { hoverCard.policy }
        set { hoverCard.policy = newValue }
    }

    /// Dragging empty strip space moves the window (titlebar strips).
    public var dragsWindowFromEmptySpace = true

    // MARK: Views

    var glassView: NSGlassEffectView?
    let contentView = FlippedView()
    let tabsClip = FlippedView()
    let fadeMask = CAGradientLayer()
    let newTabButton = NewTabButtonView()
    let hoverCard = TabHoverCardController()
    var trackingArea: NSTrackingArea?

    // MARK: Layout and animation state

    struct Motion {
        var x: Spring
        var width: Spring
        var alpha: Spring

        init(x: CGFloat, width: CGFloat, alpha: CGFloat) {
            self.x = Spring(value: x)
            self.width = Spring(value: width)
            self.alpha = Spring(value: alpha, response: 0.2, dampingRatio: 1)
        }

        var isSettled: Bool { x.isSettled && width.isSettled && alpha.isSettled }

        mutating func snap() {
            x.snap()
            width.snap()
            alpha.snap()
        }
    }

    var tabViews: [TabID: TabView] = [:]
    var motion: [TabID: Motion] = [:]
    var dying: Set<TabID> = []
    /// Tabs in visual order, excluding dying and torn-out tabs.
    var displayed: [TabItem] = []
    var result = TabLayoutResult(slots: [], contentWidth: 0, standardWidth: 0, availableWidth: 0)
    var scroll = Spring(value: 0, response: 0.32, dampingRatio: 1)
    var closingModeWidth: CGFloat?
    var hasSynced = false
    var lastSelectedID: TabID?
    var lastModelOrder: [TabID] = []
    var lastStyle: TabStripStyle?
    var lastViewportWidth: CGFloat = -1
    var displayLink: CADisplayLink?
    var lastFrameTime: CFTimeInterval?
    var observationTask: Task<Void, Never>?
    var tokenObservationTask: Task<Void, Never>?

    // MARK: Pointer state

    var hoveredID: TabID?
    var closeHoveredID: TabID?
    var pressedCloseID: TabID?
    var middlePressID: TabID?
    var pressedNewTab = false
    var hoverCardSuppressed = false

    struct Press {
        var id: TabID
        var start: CGPoint
    }

    struct Drag {
        var id: TabID
        var grabOffset: CGFloat
        var originalIndex: Int
        var currentIndex: Int
        var isPinned: Bool
        var lastPoint: CGPoint
    }

    var press: Press?
    var drag: Drag?
    /// Order shown after a local reorder until the model's order changes.
    var orderOverride: [TabID]?
    /// Tab torn out of this strip and handed to the App's drag session. Its
    /// slot stays collapsed until the model drops it or the App restores it.
    var detachedID: TabID?
    /// Display index of the phantom gap shown for an external drag.
    var dropPlaceholderIndex: Int?
    /// Pointer of the external drag, in view coordinates, for edge autoscroll.
    var phantomPoint: CGPoint?
    var escapeMonitor: Any?
    /// A dropped tab keeps the placeholder's geometry when it arrives.
    var pendingDrop: (id: TabID, x: CGFloat, width: CGFloat)?
    static let placeholderID = TabID("__cmux.tabs.drop-placeholder__")

    // MARK: - Init

    public init(model: TabStripModel, background: Background = .none) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: Self.preferredHeight))
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        switch background {
        case .none:
            addSubview(contentView)
        case .glass:
            // Concentric corners: the strip radius is the tab radius plus the inset around tabs.
            let glass = Glass.makePanel(content: contentView, cornerRadius: metrics.cornerRadius + metrics.stripVerticalPadding)
            glass.translatesAutoresizingMaskIntoConstraints = true
            addSubview(glass)
            glassView = glass
        }
        contentView.wantsLayer = true
        tabsClip.wantsLayer = true
        tabsClip.layer?.masksToBounds = true
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        contentView.addSubview(tabsClip)
        contentView.addSubview(newTabButton)
        newTabButton.onPress = { [weak self] in self?.model.send(.newTab(after: nil)) }

        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(Strings.axStrip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: metrics.stripHeight)
    }

    // Every event is handled here, never by a tab subview.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    public override func accessibilityChildren() -> [Any]? {
        displayed.compactMap { tabViews[$0.id] } + (newTabButton.isHidden ? [] : [newTabButton])
    }

    // MARK: - Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            applyTokens(animated: false)
            startObserving()
            startObservingTokens()
            sync(fromModel: true)
        } else {
            observationTask?.cancel()
            observationTask = nil
            tokenObservationTask?.cancel()
            tokenObservationTask = nil
            displayLink?.invalidate()
            displayLink = nil
            lastFrameTime = nil
            hoverCard.hide(allowsQuickReshow: false)
            removeEscapeMonitor()
        }
    }

    func startObserving() {
        guard observationTask == nil else { return }
        let model = model
        observationTask = Task { [weak self] in
            let changes = Observations {
                ModelSnapshot(tabs: model.tabs, selectedID: model.selectedID, style: model.style, showsNewTabButton: model.showsNewTabButton)
            }
            for await _ in changes {
                guard let self else { return }
                self.sync(fromModel: true)
            }
        }
    }

    /// Re-applies design tokens whenever `DesignSettings` changes. Reading
    /// the tokens inside `Observations` registers the dependency; nothing is
    /// cached in statics.
    func startObservingTokens() {
        guard tokenObservationTask == nil else { return }
        tokenObservationTask = Task { [weak self] in
            let changes = Observations { TokenSnapshot(metrics: TabStripMetrics(), titleFont: Typography.body.pointSize) }
            for await snapshot in changes {
                guard let self else { return }
                if snapshot.metrics != self.metrics || snapshot.titleFont != self.tabTitleFontSize {
                    self.applyTokens(animated: true)
                }
            }
        }
    }

    struct TokenSnapshot: Equatable, Sendable {
        var metrics: TabStripMetrics
        var titleFont: CGFloat
    }

    /// Current tab title font size, for change detection.
    var tabTitleFontSize: CGFloat { tabViews.values.first?.titleFont.pointSize ?? Typography.body.pointSize }

    func applyTokens(animated: Bool) {
        metrics = customMetrics ?? TabStripMetrics()
        hoverCard.metrics = metrics
        hoverCard.tokensChanged()
        let font = Typography.body
        for view in tabViews.values {
            view.metrics = metrics
            view.titleFont = font
        }
        newTabButton.needsLayout = true
        glassView?.cornerRadius = metrics.cornerRadius + metrics.stripVerticalPadding
        invalidateIntrinsicContentSize()
        lastViewportWidth = -1
        needsLayout = true
        layoutSubtreeIfNeeded()
        relayout(animated: animated && !reduceMotion)
    }

    struct ModelSnapshot: Sendable {
        var tabs: [TabItem]
        var selectedID: TabID?
        var style: TabStripStyle
        var showsNewTabButton: Bool
    }

    public override func layout() {
        super.layout()
        glassView?.frame = bounds
        if glassView == nil { contentView.frame = bounds }
        let showsButton = model.showsNewTabButton
        let padding = metrics.stripHorizontalPadding
        let viewport = max(0, bounds.width - 2 * padding - (showsButton ? metrics.newTabButtonWidth : 0))
        tabsClip.frame = CGRect(x: padding, y: 0, width: viewport, height: bounds.height)
        if viewport != lastViewportWidth {
            lastViewportWidth = viewport
            // Chrome resizes tabs with the window instantly.
            relayout(animated: false)
        } else {
            applyFrames()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var viewportWidth: CGFloat { tabsClip.bounds.width }

    /// Tabs are vertically centered in whatever height the strip gets.
    var tabTop: CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (max(0, (bounds.height - metrics.tabHeight) / 2) * scale).rounded() / scale
    }
}
