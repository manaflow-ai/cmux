import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

/// Where the transcript is scrolled: pinned to the newest row, or a row key
/// and its top on screen (y-down points). Prepends and evictions change row
/// indexes and tops, never this, so what is on screen does not move.
struct TranscriptAnchor: Equatable {
    var pinned = true
    var key: String?
    var top: CGFloat = 0
    /// Where `key` was last seen in the rows: a lookup hint, never the identity.
    var index = 0
}

/// The virtualized conversation transcript (MessagesLab `appkit-virtual`
/// ported): a bounded window of the source, rows laid out by prefix sums,
/// recycled `RowLayer`s showing bitmaps rasterized on background threads, and
/// render-server motion. It renders on events only (scroll, a change, a page
/// chunk); the paging frame client runs only while a page is joining.
final class TranscriptView: NSView {
    // Inputs
    var source: (any HomeTranscriptSource)? { didSet { if source !== oldValue { attachSource() } } }
    /// Space at the bottom covered by the floating composer.
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { render() } } }
    var onTypingChange: (([String]) -> Void)?
    /// The newest confirmed seq came on screen (mark read).
    var onSawNewest: ((Int) -> Void)?
    var onRetry: ((String) -> Void)?
    /// Main-thread milliseconds of each render (bench).
    var onRender: ((Double) -> Void)?

    // Engine
    let measurer = Measurer()
    private(set) lazy var rasterizer = RowRasterizer { [weak self] in self?.rasterReady() }
    var history = TranscriptWindow()
    var rowLayout = TranscriptLayout()
    var geometry = TranscriptGeometry.make(width: 600, fontSize: 13, captionSize: 11, space: (2, 4, 6, 8, 10, 12))
    var colors = TranscriptColors.neutralDark { didSet { themeGeneration += 1 } }
    var themeGeneration = 0
    var strings = RowStrings.localized()
    var meID = ""
    var typingIDs: [String] = []
    var readThrough: Int?
    var scale: CGFloat = 2
    var colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Scroll
    var anchor = TranscriptAnchor()
    var lastBase: CGFloat = 0
    /// Scroll distance of the latest event (points; positive = toward older).
    var scrollVelocity: CGFloat = 0
    var lastSawNewest = 0
    var lastScrollTime: CFTimeInterval = 0
    /// After the last scroll event: draws rows a fast scroll left as placeholders.
    let scrollSettle = DemandTimer(owner: "home.transcript.scrollSettle")
    /// After the last width change: rewraps bubbles deferred during a resize.
    let rewrap = DemandTimer(owner: "home.transcript.rewrap")
    private(set) lazy var coalescer = RenderCoalescer { [weak self] in self?.renderNow() }
    /// Main-thread milliseconds by area since the bench last reset them.
    var perf = TranscriptPerf()

    // Layers
    let contentLayer = CALayer()
    var live: [String: RowLayer] = [:]
    var pool: [RowLayer] = []
    var maxLiveLayers = 0
    var placeholdersShown = 0

    // Motion
    let committer = MotionCommitter()
    var rowMotion: [String: [MotionComponent]] = [:]
    var rowFade: [String: [MotionComponent]] = [:]
    var committedTop: [String: CGFloat] = [:]
    var pendingEvent: (time: Double, timing: TranscriptTiming)?
    var flights: [String: SendFlight] = [:]
    /// The composer text that is leaving, until its pending row appears.
    var flightGhost: (rect: CGRect, text: String, time: Double)?
    var pendingFlights: [String: (ghost: CGRect, time: Double)] = [:]
    let cleanup = DemandTimer(owner: "home.transcript.cleanup")

    // Paging
    var observation: HomeObservation?
    var pendingOlder: [HomeMessage] = []
    var pendingNewer: [HomeMessage] = []
    var loadingOlder = false
    var loadingNewer = false
    /// Bumped by attach and jumps: page loads of an older generation are dropped.
    var generation = 0
    private(set) lazy var pagingClient = FrameClient(
        owner: "home.transcript.paging", isAnimation: false,
        scheduler: { [weak self] in self.map(FrameScheduler.forView) ?? .app }
    ) { [weak self] _ in self?.pagingFrame() ?? false }

    static let pageSize = 400
    static let prefetchMessages = 900
    static let chunkSize = 100
    static let jumpSize = 200

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        contentLayer.actions = RowLayer.noActions
        contentLayer.masksToBounds = true
        layer?.addSublayer(contentLayer)
        strings = RowStrings.localized()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry, theme, scale

    override func layout() {
        super.layout()
        contentLayer.frame = bounds
        updateGeometry()
        render()
    }

    /// Applies the geometry for the current width. A pure width change keeps
    /// the bubble wrap width while the old bubbles still fit (only x moves,
    /// cheap per resize frame) and rewraps once the width rests.
    func updateGeometry(deferRewrap: Bool = true) {
        var next = TranscriptGeometry.current(width: bounds.width)
        guard next != geometry else { return }
        let restyled = next.fontSize != geometry.fontSize || next.captionSize != geometry.captionSize
            || next.insetX != geometry.insetX || next.insetY != geometry.insetY
        let rewraps = restyled || next.maxTextWidth != geometry.maxTextWidth
        let stillFits = geometry.maxBubbleWidth + 2 * next.sideMargin <= next.width
        if rewraps, deferRewrap, !restyled, stillFits, !rowLayout.isEmpty {
            next.maxTextWidth = geometry.maxTextWidth
            next.workCardWidth = geometry.workCardWidth
            geometry = next
            rowLayout.reflow(to: next)
            rewrap.schedule(after: .milliseconds(150)) { @MainActor [weak self] in
                self?.updateGeometry(deferRewrap: false)
                self?.render()
            }
            return
        }
        geometry = next
        if rewraps {
            rowLayout.rebuild(history, context: context())
        } else {
            rowLayout.reflow(to: next)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let next = performWithTheme { TranscriptColors.resolveInScope() }
        guard next != colors else { return }
        colors = next
        rasterizer.removeAll()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let next = window?.backingScaleFactor ?? 2
        if let space = window?.screen?.colorSpace?.cgColorSpace { colorSpace = space }
        guard next != scale else { return }
        scale = next
        rasterizer.removeAll()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        viewDidChangeBackingProperties()
        viewDidChangeEffectiveAppearance()
    }

    func context() -> RowContext {
        RowContext(meID: meID, geometry: geometry, now: Date(), readThrough: readThrough, typing: !typingIDs.isEmpty,
                   strings: strings, measurer: measurer)
    }

    var viewportBottom: CGFloat { bounds.height - bottomInset }

    /// A frame in transcript (y-down) points as a layer frame (y-up).
    func layerFrame(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Input

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * geometry.lineHeight * 3
        guard dy != 0 else { return }
        scroll(by: dy)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let y = bounds.height - point.y - lastBase
        let index = rowLayout.firstRow(endingAtOrBelow: y)
        guard index < rowLayout.rows.count else { return }
        let row = rowLayout.rows[index]
        let top = rowLayout.tops[index]
        guard y >= top, point.x >= row.x - geometry.lineHeight * 2, point.x <= row.x + row.width,
              let key = row.messageKey,
              let message = history.index(ofRowKey: key).map({ history[$0] }) else { return }
        if case .failed = message.delivery { onRetry?(message.clientMsgID) }
    }

    func rasterReady() {
        rasterizer.wakeHandled()
        render()
    }

    /// Applies a window mutation to the rows and keeps the anchor's row index hint current.
    func applyToRows(_ change: WindowChange) {
        guard change != .none else { return }
        rowLayout.apply(change, window: history, context: context())
        anchor.index += rowLayout.lastFrontShift
    }
}
