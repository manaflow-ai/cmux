public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The thin rail (`sidebar.style` = rail, plans/cmux-next/minimal-sidebar.md): one short tick
/// per workspace in sidebar order, a collapsed group as one tick, a gap between groups. The
/// selected tick spans the rail; unread ticks take the unread color; working ticks are brighter.
/// Nothing animates here, so the rail costs no frames at rest (Reduce Motion has nothing to stop).
///
/// The container shows it while the full sidebar is closed. Pointing at a mark shows that
/// workspace's hover card beside its row (`SidebarRailHoverCards`); a click on a mark selects that
/// workspace. The full sidebar opens only from Toggle Sidebar (`SidebarModel.toggle`).
public final class SidebarRailView: NSView {
    /// The rail's hover card source; the pointer goes to it.
    weak var cards: SidebarRailHoverCards?
    private(set) weak var model: SidebarModel?
    private var observation: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?
    /// The ticks drawn now, in this view's (flipped) coordinates.
    private(set) var railLayout = SidebarRailLayout(groups: [], top: 0, available: 0)
    private var marks: [[SidebarRailMark]] = []

    override public var isFlipped: Bool { true }
    /// Ticks start at the trailing edge (a sidebar on the window's right side).
    var hugsTrailingEdge = false {
        didSet { if hugsTrailingEdge != oldValue { needsDisplay = true } }
    }

    /// The first tick's top: below the traffic lights' row.
    var topInset: CGFloat = Metrics.titlebarHeight + Metrics.space3 {
        didSet { if topInset != oldValue { relayout() } }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.railLabel)
        setAccessibilityIdentifier("sidebar.rail")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    /// Draws `model`'s workspaces and follows them.
    func bind(_ model: SidebarModel) {
        self.model = model
        marks = Self.marks(model)
        relayout()
        observation?.cancel()
        observation = Task { [weak self] in
            for await marks in ObservationStream({ Self.marks(model) }) {
                guard let self, marks != self.marks else { continue }
                self.marks = marks
                self.relayout()
            }
        }
    }

    /// The marks of `model`, one array per group or run of loose workspaces.
    static func marks(_ model: SidebarModel) -> [[SidebarRailMark]] {
        let active = model.activeWorkspaceID
        var runs: [[SidebarRailMark]] = []
        for section in model.sections {
            var loose: [SidebarRailMark] = []
            for node in section.nodes {
                switch node {
                case let .workspace(workspace):
                    loose.append(SidebarRailMark(workspace: workspace, isSelected: workspace.id == active))
                case let .group(group):
                    if !loose.isEmpty { runs.append(loose) }
                    loose = []
                    let members = group.workspaces.map { SidebarRailMark(workspace: $0, isSelected: $0.id == active) }
                    guard !members.isEmpty else { continue }
                    if group.isCollapsed {
                        let state = members.map(\.state).max() ?? .idle
                        runs.append([SidebarRailMark(target: .group(group.id), isSelected: members.contains(where: \.isSelected), state: state)])
                    } else {
                        runs.append(members)
                    }
                case .item:
                    continue
                }
            }
            if !loose.isEmpty { runs.append(loose) }
        }
        return runs
    }

    override public func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        let next = SidebarRailLayout(groups: marks, top: topInset, available: max(0, bounds.height - topInset - Metrics.space4))
        guard next != railLayout else { return }
        railLayout = next
        needsDisplay = true
    }

    override public func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            for tick in railLayout.ticks {
                var rect = tick.rect
                if hugsTrailingEdge { rect.origin.x = bounds.width - rect.maxX }
                guard rect.intersects(dirtyRect) else { continue }
                Self.color(tick.mark).setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            }
        }
    }

    private static func color(_ mark: SidebarRailMark) -> NSColor {
        if mark.state == .unread { return Palette.notificationBlue }
        if mark.isSelected { return Palette.textPrimary }
        return mark.state == .working ? Palette.textSecondary : Palette.textTertiary.withAlphaComponent(0.6)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Pointer

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override public func mouseMoved(with event: NSEvent) { pointer(event) }
    override public func mouseEntered(with event: NSEvent) { pointer(event) }
    override public func mouseExited(with event: NSEvent) { pointer(event) }

    private func pointer(_ event: NSEvent) {
        cards?.pointerMoved(to: window.map { $0.convertPoint(toScreen: event.locationInWindow) })
    }

    override public func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let model, let tick = tick(at: point), case let .workspace(id) = tick.mark.target else { return }
        model.noteUserIntent()
        model.click(id)
    }

    /// The tick whose row holds `point` (this view's coordinates): rows of a group touch, so a
    /// pointer on the rail is on a row except in a gap between groups.
    func tick(at point: CGPoint) -> SidebarRailLayout.Tick? {
        guard point.x >= 0, point.x < bounds.width else { return nil }
        return railLayout.ticks.first { point.y >= $0.rowY && point.y < $0.rowY + railLayout.pitch }
    }

    /// The middle of a mark's row in window coordinates, for a synthetic pointer
    /// (`debug.pointer_hover {rail: "top" | "middle" | "bottom" | index}`); nil while the rail is hidden.
    public func rowCenterInWindow(_ which: String) -> CGPoint? {
        let ticks = railLayout.ticks
        guard !isHiddenOrHasHiddenAncestor, !ticks.isEmpty else { return nil }
        let index = switch which {
        case "top": 0
        case "middle": ticks.count / 2
        case "bottom": ticks.count - 1
        default: min(max(Int(which) ?? 0, 0), ticks.count - 1)
        }
        let row = railLayout.row(of: ticks[index], railWidth: bounds.width)
        return convert(CGPoint(x: row.midX, y: row.midY), to: nil)
    }

    /// `tick`'s hover card anchor: its row as a band across the sidebar column, the list rows' one
    /// rule (`HoverCardEscapeGeometry.rowBand`). Nil out of a window.
    func cardAnchor(_ tick: SidebarRailLayout.Tick) -> CGRect? {
        guard let row = rowOnScreen(tick), let column = sidebarColumnOnScreen else { return nil }
        return HoverCardEscapeGeometry.rowBand(row: row, column: column)
    }

    /// `tick`'s row on screen; nil out of a window.
    func rowOnScreen(_ tick: SidebarRailLayout.Tick) -> CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(railLayout.row(of: tick, railWidth: bounds.width), to: nil))
    }

    // MARK: Shortcut hints

    /// Each tick's hint target in this view's coordinates: as tall as a chip and wide enough
    /// that the chip sits just past the rail, over the content's edge.
    public var shortcutHintItemFrames: [SidebarItem: CGRect] {
        guard !isHiddenOrHasHiddenAncestor, bounds.width > 0 else { return [:] }
        var result: [SidebarItem: CGRect] = [:]
        for tick in railLayout.ticks {
            let item: SidebarItem = switch tick.mark.target {
            case let .workspace(id): .workspace(id)
            case let .group(id): .group(id)
            }
            let x = hugsTrailingEdge ? -Self.hintReach : 0
            result[item] = CGRect(x: x, y: tick.rect.midY - 8, width: bounds.width + Self.hintReach, height: 16)
        }
        return result
    }

    /// How far past the rail a hint chip may reach.
    static let hintReach: CGFloat = 34
}
