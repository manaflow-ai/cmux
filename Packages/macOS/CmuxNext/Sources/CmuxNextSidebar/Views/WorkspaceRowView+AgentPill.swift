import AppKit
import CmuxNextDesign
import QuartzCore

/// `experiments.agentBadges` (Settings > Advanced > Experiments, off by default; taste build 5, 2026-11-19). Leo: "sidebar rows
/// get one tinted status pill (Running, Needs approval, Done); variant: a thin light beam travels along the row edge
/// while an agent runs." Off draws the shipped row: no pill view, no beam view, no reserved width.
///
/// A row's one status pill, read from the state the row already has (no new feed). Idle, failed and lost rows show
/// none: they keep their shipped status mark.
nonisolated enum SidebarAgentPill: Hashable, Sendable, CaseIterable {
    case running
    case needsApproval
    case done

    /// The pill `ws` shows; nil for none. Waiting on the person wins over work (a chat that asks while another runs
    /// asks first), work wins over a finish nobody has seen.
    static func of(_ ws: SidebarWorkspace) -> SidebarAgentPill? {
        if ws.agentChip == .needsYou { return .needsApproval }
        if case .waiting = ws.activity { return .needsApproval }
        if ws.agentWorking { return .running }
        switch ws.agentChip {
        case .working?: return .running
        case .done?: return .done
        case .needsYou?, .failed?, .lost?, .ciFailing?, .idle?, nil: break
        }
        switch ws.activity {
        case .working, .busy: return .running
        case .success: return ws.unread.isUnread ? .done : nil
        case .idle, .paused, .error, .waiting: return nil
        }
    }

    /// The pill's words, also what VoiceOver says (in Leo's words, sentence case).
    @MainActor var title: String {
        switch self {
        case .running: Strings.agentPillRunning
        case .needsApproval: Strings.agentPillNeedsApproval
        case .done: Strings.priorityDone
        }
    }

    /// Running in the theme's green, needs approval in its attention colour (as every waiting-on-you mark), done in its
    /// highlight (the unseen blue). The fill is the tint at `fillAlpha`, the words the tint itself.
    @MainActor var tint: NSColor {
        switch self {
        case .running: Palette.success
        case .needsApproval: Palette.statusAttention
        case .done: Palette.highlight
        }
    }

    static let fillAlpha: CGFloat = 0.16

    /// The pill's words: the caption step, emphasized.
    @MainActor static var font: NSFont { Typography.system(.default, size: TypeScale.caption, weight: TypeScale.emphasis) }
    /// Room each side of the words.
    @MainActor static var padding: CGFloat { Metrics.space1 + Metrics.space1 / 2 }

    /// The capsule's height for `font`: its line and a point above and below.
    @MainActor static func height(font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) + 2 }

    /// The capsule's width around `text` in `font`.
    @MainActor static func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 * padding
    }

    @MainActor func width(font: NSFont) -> CGFloat { Self.width(title, font: font) }

    /// The width every row reserves while the pills are on: the widest pill's (Needs approval in English, whichever is
    /// widest in the person's language), whatever the row shows, so no title moves as its pill comes, changes or goes.
    @MainActor static func reservedWidth(font: NSFont) -> CGFloat {
        allCases.map { $0.width(font: font) }.max() ?? 0
    }
}

/// The row's status pill: a capsule tinted by its state, its words in the tint, right-aligned in the reserved slot
/// (the view's frame, which no state changes). Takes no click and is no accessibility element: the row's label says
/// the words.
final class SidebarAgentPillView: NSView {
    private let capsule = CALayer()
    let label = SidebarRowView.label(font: SidebarAgentPill.font)
    private(set) var pill: SidebarAgentPill?
    /// This row's last measured reserve (the font changes only with the text size setting), so a layout pass measures
    /// the labels once per font, not on every pass.
    private var reserve: (font: NSFont, width: CGFloat)?

    /// `SidebarAgentPill.reservedWidth(font:)`, measured once per font.
    func reservedWidth(font: NSFont) -> CGFloat {
        if let reserve, reserve.font == font { return reserve.width }
        let width = SidebarAgentPill.reservedWidth(font: font)
        reserve = (font, width)
        return width
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(capsule)
        addSubview(label)
        label.isHidden = true
        capsule.isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `pill` (nil: the empty slot). `animated`: the same workspace's state changed, so the old pill cross-fades
    /// into the new one in place (the sidebar's gate: none with its animations off; Reduce Motion keeps the fade).
    func show(_ pill: SidebarAgentPill?, animated: Bool) {
        guard pill != self.pill else { return }
        self.pill = pill
        if animated { Motion.sidebar.crossfadeInPlace(layer) }
        label.setString(pill?.title ?? "")
        label.isHidden = pill == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.isHidden = pill == nil
        CATransaction.commit()
        needsLayout = true
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard let pill else { return }
        let font = SidebarAgentPill.font
        label.setFont(font)
        let w = min(bounds.width, pill.width(font: font)), h = min(bounds.height, SidebarAgentPill.height(font: font))
        let scale = window?.backingScaleFactor ?? 2
        let rect = CGRect(x: SidebarStyle.pixelSnapped(bounds.maxX - w, scale: scale),
                          y: SidebarStyle.pixelSnapped((bounds.height - h) / 2, scale: scale), width: w, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = rect
        capsule.cornerRadius = h / 2
        CATransaction.commit()
        let text = label.intrinsicContentSize
        let pad = SidebarAgentPill.padding
        label.frame = label.frame(forAlignmentRect: NSRect(x: rect.minX + pad, y: 0, width: max(0, w - 2 * pad), height: ceil(text.height)))
        label.frame.origin.y = SidebarStyle.textY(label, centerY: rect.midY)
    }

    override func updateLayer() {
        performWithTheme {
            guard let pill else { return }
            let tint = pill.tint
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            capsule.backgroundColor = tint.withAlphaComponent(SidebarAgentPill.fillAlpha).cgColor
            CATransaction.commit()
            label.setColor(tint)
        }
    }
}

/// `experiments.agentBadges` `beam`: while the row's agent runs, a thin light segment laps the row's rounded edge. One
/// Core Animation loop in the render server per running row on screen, no timer: it is paced by the indicators gate's
/// loop period (`Motion.indicators`, nil under Reduce Motion, calm mode, animations off or the indicators category
/// off; the edge then stays a faint still line). It stops the moment the row stops running, and while the row is
/// parked (a pooled row is hidden), out of a window, or its window is covered, minimized or on another Space.
final class SidebarAgentBeamView: NSView {
    private let edge = CAShapeLayer()
    /// The row's agent runs and the experiment draws the beam.
    var isRunning = false { didSet { if isRunning != oldValue { refresh() } } }
    /// The row fill's corner (the beam follows the fill's edge).
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue, isRunning { refresh() } } }
    /// The list's reading of its window's occlusion (`SidebarListView.setWindowVisible`).
    private(set) var isWindowVisible = true
    /// A lap runs now (the moving look); false: the still look, or nothing.
    private(set) var laps = false
    private var motion: MotionSubscription?
    private var drawnSize: CGSize = .zero
    private var refreshing = false

    static let lapKey = "cmux.sidebar.agentBeam"
    /// The line's weight.
    static let lineWidth: CGFloat = 1.5
    /// The light's length along the edge.
    static var segment: CGFloat { LayoutGrid.iconBox * 2 }
    /// One lap takes this many of the indicators gate's `breath` periods: a calm light, never a flash.
    static let breathsPerLap: Double = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        edge.fillColor = nil
        edge.lineWidth = Self.lineWidth
        edge.lineCap = .round
        layer?.addSublayer(edge)
        setAccessibilityElement(false)
        isHidden = true
        // A Reduce Motion, calm mode or animation switch change starts or stops the lap at once.
        motion = Motion.changes.subscribe { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The list read its window again (`SidebarListView.setWindowVisible`): a covered window stops the lap, a shown one
    /// starts it.
    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        if isRunning { refresh() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isRunning || laps { refresh() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        if laps { refresh() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if isRunning { refresh() }
    }

    /// A new size is a new edge: the path and the lap's length follow it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize != drawnSize else { return }
        drawnSize = newSize
        if isRunning { refresh() }
    }

    /// The rounded edge, a half line inside the bounds, and its length.
    private func edgePath() -> (path: CGPath, length: CGFloat)? {
        let rect = bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let r = max(0, min(cornerRadius - Self.lineWidth / 2, rect.width / 2, rect.height / 2))
        let length = 2 * (rect.width + rect.height) - 8 * r + 2 * .pi * r
        return (CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil), length)
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if isHidden == isRunning { isHidden = !isRunning }
        edge.removeAnimation(forKey: Self.lapKey)
        laps = false
        guard isRunning, let drawn = edgePath() else {
            needsDisplay = true
            return
        }
        let (path, length) = drawn
        let shown = isWindowVisible && !isHiddenOrHasHiddenAncestor
            && window.map { $0.isVisible && $0.occlusionState.contains(.visible) } == true
        let period = shown ? Motion.indicators.period(.breath) : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = bounds
        edge.path = path
        if let period, length > Self.segment {
            // One dash the light's length and one gap the rest of the edge: the pattern is exactly one lap, so moving
            // its phase by the edge's length brings the light back where it started, with no seam.
            edge.lineDashPattern = [NSNumber(value: Double(Self.segment)), NSNumber(value: Double(length - Self.segment))]
            // `period` is Motion.indicators.period(.breath): nil (no lap) under Reduce Motion, calm mode, animations off
            // motion: allow a render-server lap paced by the indicators gate's loop period (above)
            let lap = CABasicAnimation(keyPath: "lineDashPhase")
            lap.fromValue = 0
            lap.toValue = length
            lap.duration = period * Self.breathsPerLap
            lap.repeatCount = .infinity
            lap.isRemovedOnCompletion = false
            edge.add(lap, forKey: Self.lapKey)
            laps = true
        } else {
            edge.lineDashPattern = nil
        }
        CATransaction.commit()
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // The moving light is bright; the still edge (no motion) is a faint line that only says the row runs.
            edge.strokeColor = Palette.success.withAlphaComponent(laps ? 0.9 : 0.3).cgColor
            CATransaction.commit()
        }
    }
}

extension WorkspaceRowView {
    /// Applies `experiments.agentBadges` after the rest of `configure`: makes the pill and beam views the first time
    /// the experiment is on, shows `pill` (cross-fading when the same workspace's state changed) and runs the beam
    /// while the row's agent runs. Off: both views (if ever made) hide, and the layout reserves nothing.
    func configureAgentBadges(_ workspace: WorkspaceID, experiment: AgentBadgesExperiment, pill: SidebarAgentPill?) {
        agentBadges = experiment
        agentPill = pill
        if experiment.showsPills, agentPillView == nil {
            let view = SidebarAgentPillView()
            addSubview(view)
            agentPillView = view
        }
        if experiment.showsBeam, agentBeamView == nil {
            let view = SidebarAgentBeamView()
            // Under the row's content, over its fill (the row's own layer).
            addSubview(view, positioned: .below, relativeTo: nil)
            agentBeamView = view
        }
        let previous = shownAgentPill?.workspace == workspace ? shownAgentPill : nil
        shownAgentPill = (workspace, pill)
        if let view = agentPillView {
            view.isHidden = !experiment.showsPills
            view.show(pill, animated: previous != nil && previous?.pill != pill && experiment.showsPills)
        }
        agentBeamView?.isRunning = experiment.showsBeam && pill == .running
    }

    /// Lays out the pill's slot on the trailing column (the shared column helper, `SidebarStyle+TrailingColumn`) and
    /// returns where every other trailing item ends, left of it; nil with the pills off. The slot is the widest
    /// pill's on every row, so the title ends at the same x whatever the row shows. Also fits the beam to the row.
    func layoutAgentBadges(rowWidth: CGFloat, cy: CGFloat, full: NSRect) -> CGFloat? {
        if let beam = agentBeamView, !beam.isHidden {
            beam.frame = full
            beam.cornerRadius = fillCornerRadius
        }
        guard agentBadges.showsPills, let view = agentPillView else { return nil }
        let columns = SidebarStyle.columns(rowWidth: rowWidth)
        let font = SidebarAgentPill.font
        let size = CGSize(width: view.reservedWidth(font: font), height: SidebarAgentPill.height(font: font))
        let slot = columns.trailingFrame(before: columns.trailingEdge, centerY: cy, size: size)
        let scale = window?.backingScaleFactor ?? 2
        view.frame = NSRect(x: SidebarStyle.pixelSnapped(slot.minX, scale: scale), y: SidebarStyle.pixelSnapped(slot.minY, scale: scale),
                            width: slot.width, height: slot.height)
        return columns.trailingEdge(before: slot)
    }
}
