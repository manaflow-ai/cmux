import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextWakeups

/// What a section or row needs from the panel: its colors and how a click reaches the page. A value,
/// not the store, so a row holds no reference to it.
struct SessionInfoInk {
    let colors: AgentPaneSessionInfoColors
    let act: (String, CGRect?) -> Void
    let rect: (NSView) -> CGRect?
    let move: (String, NSView, NSPoint) -> Void
    let flush: () -> Void

    init(colors: AgentPaneSessionInfoColors, act: @escaping (String, CGRect?) -> Void, rect: @escaping (NSView) -> CGRect?, move: @escaping (String, NSView, NSPoint) -> Void = { _, _, _ in }, flush: @escaping () -> Void = {}) {
        self.colors = colors
        self.act = act
        self.rect = rect
        self.move = move
        self.flush = flush
    }
}

/// The panel's grid, the web panel's (sessionInfo.css) on the shared layout grid (design/grid.md
/// section 3): a line's highlight sits `edge` in from the panel; inside it every header and row puts
/// its icon in one 16 box at `lead`, starts its title on `text` (lead + box + 8) whether or not it has
/// an icon, and ends its trailing value or control `trail` in from the highlight's right end.
enum SessionInfoMetrics {
    /// The panel's edge to a line's highlight (the web body's side padding).
    static let edge: CGFloat = LayoutGrid.sidebarHighlightInset
    /// The panel's edge to the icon column (`lead`).
    static let inset: CGFloat = edge + LayoutGrid.gap
    /// The icon column's box; every leading mark centers in it, whatever its glyph's size.
    static let iconBox: CGFloat = LayoutGrid.iconBox
    /// Chevrons, spinners and other small marks draw at this size, centered in the icon box.
    static let glyph: CGFloat = LayoutGrid.glyph
    /// A line's highlight to its title column (`text`): lead, the icon box, then one gap.
    static let text: CGFloat = LayoutGrid.gap + iconBox + LayoutGrid.gap
    /// A line's highlight's right end to its trailing column's right edge.
    static let trail: CGFloat = LayoutGrid.gap
    static let rowHeight: CGFloat = LayoutGrid.row
    static let rowRadius: CGFloat = 6
    static let indent: CGFloat = LayoutGrid.sidebarDepthIndent
    static let groupGap: CGFloat = LayoutGrid.gapInner
    static let padding: CGFloat = LayoutGrid.gap
}

/// One line of the panel, as values: a section's title row, a row, or a section's "View all".
struct SessionInfoLine: Equatable {
    enum Kind: Equatable { case title, header, row, more }
    var id: String?
    var kind: Kind
    var symbol: String?
    var symbolColor: String?
    var harness: String?
    var identityTone: Int?
    var working = false
    var wave: AgentPaneSessionInfoModel.Wave?
    var spins = false
    var title: String
    var titleInk: Ink = .primary
    var detail: String?
    var subtitle: String?
    var progress: String?
    var trailing: String?
    var trailingTone: AgentPaneSessionInfoModel.Tone?
    /// A foldable section's chevron: true while it is unfolded.
    var unfolded: Bool?
    var meter: Double?
    var segments: [AgentPaneSessionInfoModel.Segment]?
    var buttons: [AgentPaneSessionInfoModel.Button] = []
    var menu: [AgentPaneSessionInfoModel.Button] = []
    var menuLabel: String?
    var reorderLabel: String?
    var toggle: Bool?
    var reorderable = false
    var hover: AgentPaneSessionInfoModel.Hover?
    var marks: [AgentPaneSessionInfoModel.Tone]?
    var indent = 0
    var action: String?
    var help: String?

    enum Ink: Equatable { case primary, secondary, danger }

    /// A row that opens a fold under it ("7 done", "N finished", MCP tools): its chevron is its icon,
    /// drawn at the small glyph size in the icon column.
    var discloses: Bool { kind == .row && (symbol == "chevron.right" || symbol == "chevron.down") }

    var font: NSFont {
        switch kind {
        case .title: Typography.bodyEmphasized
        // A section's title is the rows' size at medium weight, the web panel's
        // `.acpmux-session-info-section__title` (font-weight 500), never the bold chrome header.
        case .header: Typography.bodyEmphasized
        case .row: Typography.body
        case .more: Typography.caption
        }
    }
}

/// The keys that press a focused line or button, as a push button's: Space and Return.
enum SessionInfoKeys {
    static func presses(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock]).isEmpty else { return false }
        return event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r"
    }
}

/// One item of the panel's list.
enum SessionInfoItem: Equatable {
    case title(String, action: String?, label: String?)
    case separator
    case line(SessionInfoLine)
}

extension AgentPaneSessionInfoModel {
    /// The panel's list: its title, then each group's sections (where it runs, what it made, what
    /// it runs) with a hairline between groups.
    var items: [SessionInfoItem] {
        var items: [SessionInfoItem] = []
        if let title { items.append(.title(title, action: back, label: backLabel)) }
        var group: String?
        for section in sections {
            if let group, group != section.group { items.append(.separator) }
            group = section.group
            let bare = section.bare == true
            if !bare {
                items.append(.line(SessionInfoLine(
                    id: section.id, kind: .header, symbol: section.symbol, title: section.title, trailing: section.meta,
                    trailingTone: section.metaTone, unfolded: section.foldable ? section.open : nil, meter: section.meter, segments: section.segments,
                    reorderLabel: section.reorderLabel, reorderable: section.reorderable == true,
                    action: section.foldable ? "fold:\(section.id):\(section.open ? 0 : 1)" : nil)))
            }
            guard section.open || bare else { continue }
            for (index, row) in section.rows.enumerated() {
                items.append(.line(SessionInfoLine(
                    id: section.bare == true && index == 0 ? section.id : "row:\(section.id):\(row.id)", kind: .row, symbol: row.symbol, symbolColor: row.symbolColor, harness: row.harness, identityTone: row.identityTone,
                    working: row.working == true, wave: row.wave, spins: false, title: row.title,
                    titleInk: row.tone == .failed ? .danger : .primary, detail: row.detail, subtitle: row.subtitle, progress: row.progress,
                    trailing: row.trailing, trailingTone: row.tone, meter: row.meter, segments: row.segments, buttons: row.buttons ?? [],
                    menu: row.menu ?? [], menuLabel: row.menuLabel, reorderLabel: section.reorderLabel, toggle: row.toggle, reorderable: section.bare == true && index == 0 && section.reorderable == true,
                    hover: row.hover, marks: row.marks,
                    indent: min(3, max(0, Int((row.indent ?? 0).rounded()))), action: row.action, help: row.help)))
            }
            if let more = section.more {
                items.append(.line(SessionInfoLine(id: "more:\(section.id)", kind: .more, title: more.label, titleInk: .secondary, action: more.action)))
            }
        }
        return items
    }
}

/// The panel's content: a scroll view over the list, drawn again when the store's model or colors
/// change. AppKit, no SwiftUI (plans/cmux-next/no-swiftui-DESIGN.md).
final class AgentPaneSessionInfoContent: NSView {
    private let scroll = NSScrollView()
    private let list = SessionInfoListView()
    private let edgeFadeMask = CAGradientLayer()
    private weak var store: AgentPaneSessionInfoStore?
    private var lastItems: [SessionInfoItem] = []
    private var lastColors = AgentPaneSessionInfoColors()
    private var lastRevealToken: Int?

    init(store: AgentPaneSessionInfoStore) {
        self.store = store
        super.init(frame: .zero)
        let clip = SessionInfoClipView(frame: .zero)
        scroll.contentView = clip
        clip.onGeometryChange = { [weak self] in self?.updateEdgeFades() }
        scroll.drawsBackground = false
        // No scroller at all, as Claude Code's panel: the list scrolls by wheel, trackpad and keyboard,
        // and the edge fades say there is more (Leo, 2026-11-03: "i mean there's literally no scrollbar
        // in claude code it's just scrollable"). The web body hides its own the same way (sessionInfo.css).
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = list
        scroll.contentView.wantsLayer = true
        edgeFadeMask.startPoint = CGPoint(x: 0.5, y: 1)
        edgeFadeMask.endPoint = CGPoint(x: 0.5, y: 0)
        scroll.contentView.layer?.mask = edgeFadeMask
        addSubview(scroll)
        store.redraw = { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        list.width = scroll.contentSize.width
        edgeFadeMask.frame = scroll.contentView.bounds
        updateEdgeFades()
    }

    private func updateEdgeFades() {
        let offset = scroll.contentView.bounds.minY
        let maxOffset = max(0, list.bounds.height - scroll.contentView.bounds.height)
        // The layer is a mask: transparent ends reveal the glass underneath while opaque middle
        // pixels leave the list untouched. At either scroll edge that end becomes fully opaque.
        let topAlpha: CGFloat = offset <= 1 ? 1 : 0
        let bottomAlpha: CGFloat = offset >= maxOffset - 1 ? 1 : 0
        let fadeFraction = min(0.5, 18 / max(1, scroll.contentView.bounds.height))
        edgeFadeMask.colors = [
            NSColor.black.withAlphaComponent(topAlpha).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(bottomAlpha).cgColor,
        ]
        edgeFadeMask.locations = [NSNumber(value: 0), NSNumber(value: Double(fadeFraction)), NSNumber(value: Double(1 - fadeFraction)), NSNumber(value: 1)]
        edgeFadeMask.frame = scroll.contentView.bounds
    }

    /// The content's height at `width`: the list's, so the panel ends after its last section.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat { list.height(forWidth: width) }

    /// The list's height changed: the panel's frame follows it (AgentPaneSessionInfoPanel).
    var onHeightChange: (() -> Void)? {
        get { list.onHeightChange }
        set { list.onHeightChange = newValue }
    }

    /// The list's views, for tests.
    var lines: [SessionInfoLineView] { list.subviews.compactMap { $0 as? SessionInfoLineView } }

    private func reload() {
        guard let store else { return }
        let items = store.info?.items ?? []
        // Keep existing AppKit rows when the page repeats an identical model. This preserves
        // menu tracking, keyboard focus and hover state across bridge updates.
        if items != lastItems || store.colors != lastColors {
            let act = store.act
            if list.show(items, ink: SessionInfoInk(colors: store.colors, act: { id, rect in act(id, rect) }, rect: store.rectForView, move: { [weak self] id, view, point in self?.list.move(from: id, view: view, point: point) }, flush: { [weak self] in self?.list.flushPending() })) {
                lastItems = items
                lastColors = store.colors
            }
        }
        list.width = scroll.contentSize.width
        if let reveal = store.info?.reveal {
            let token = Int(reveal.at.rounded())
            guard token != lastRevealToken else { return }
            lastRevealToken = token
            list.reveal(section: reveal.section)
        }
    }
}

/// Clip view callbacks avoid NotificationCenter's process-wide observer lifetime and keep edge
/// fades in sync with AppKit's bounds changes while the panel is resized or scrolled.
private final class SessionInfoClipView: NSClipView {
    var onGeometryChange: (() -> Void)?

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        onGeometryChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onGeometryChange?()
    }
}

/// The list's document view: its items laid out top down at the scroll view's width.
final class SessionInfoListView: NSView {
    override var isFlipped: Bool { true }
    private var items: [SessionInfoItem] = []
    private var ink = SessionInfoInk(colors: AgentPaneSessionInfoColors(), act: { _, _ in }, rect: { _ in nil }, move: { _, _, _ in }, flush: {})
    private var pendingItems: [SessionInfoItem]?
    private var pendingInk: SessionInfoInk?
    /// Clears a revealed row's highlight; a new reveal replaces the pending one.
    private let revealTimer = DemandTimer(owner: "SessionInfo.reveal")
    var width: CGFloat = 0 { didSet { if width != oldValue { place() } } }
    /// The list's height changed (new items, a fold, a new width): the panel's frame follows it.
    var onHeightChange: (() -> Void)?

    @discardableResult
    func show(_ items: [SessionInfoItem], ink: SessionInfoInk) -> Bool {
        if subviews.compactMap({ $0 as? SessionInfoLineView }).contains(where: { $0.isDragging || $0.isMenuOpen }) {
            pendingItems = items
            pendingInk = ink
            return false
        }
        let firstResponder = window?.firstResponder
        let focusedLine = firstResponder as? SessionInfoLineView
        let focusedIdentity = focusedLine?.line.id
        let focusedButton = firstResponder as? SessionInfoButtonView
        let focusedButtonLine = focusedButton.flatMap { button in
            subviews.compactMap { $0 as? SessionInfoLineView }.first { $0.buttons.contains { $0 === button } }
        }
        let focusedButtonAction = focusedButton?.button.action
        let origin = enclosingScrollView?.contentView.bounds.origin
        let existingLines = subviews.compactMap { $0 as? SessionInfoLineView }
            .reduce(into: [String: SessionInfoLineView]()) { result, line in
                guard let identity = line.line.id, result[identity] == nil else { return }
                result[identity] = line
            }
        self.items = items
        self.ink = ink
        subviews.forEach { $0.removeFromSuperview() }
        for item in items {
            switch item {
            case .title(let title, let action, let backLabel):
                let label: NSView
                if let action {
                    let line = SessionInfoLine(
                        id: "title", kind: .title, symbol: "chevron.left", title: backLabel ?? title,
                        detail: nil, action: action)
                    if let old = existingLines[line.id ?? ""] {
                        if !old.matches(line: line, ink: ink) { old.update(line: line, ink: ink) }
                        label = old
                    } else {
                        label = SessionInfoLineView(line: line, ink: ink)
                    }
                } else {
                    let plain = ChromeLabel(labelWithString: title)
                    plain.font = Typography.bodyEmphasized
                    plain.textColor = ink.colors.primary
                    plain.lineBreakMode = .byTruncatingTail
                    label = plain
                }
                addSubview(label)
            case .separator:
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = ink.colors.separator.cgColor
                addSubview(line)
            case .line(let value):
                if let identity = value.id, let old = existingLines[identity] {
                    if !old.matches(line: value, ink: ink) { old.update(line: value, ink: ink) }
                    addSubview(old)
                } else {
                    addSubview(SessionInfoLineView(line: value, ink: ink))
                }
            }
        }
        place()
        if let origin, let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if let focusedButtonLine, let focusedButtonAction,
           let line = subviews.compactMap({ $0 as? SessionInfoLineView }).first(where: { $0.line.id == focusedButtonLine.line.id }),
           let button = line.buttons.first(where: { $0.button.action == focusedButtonAction }) {
            window?.makeFirstResponder(button)
        } else if let focusedIdentity,
                  let focused = subviews.compactMap({ $0 as? SessionInfoLineView }).first(where: { $0.line.id == focusedIdentity }) {
            window?.makeFirstResponder(focused)
        }
        pendingItems = nil
        pendingInk = nil
        return true
    }

    func flushPending() {
        guard let pendingItems, let pendingInk else { return }
        _ = show(pendingItems, ink: pendingInk)
    }

    func move(from id: String, view: NSView, point: NSPoint) {
        let drop = convert(point, from: view)
        let candidates = subviews.compactMap { $0 as? SessionInfoLineView }
            .filter { ($0.line.kind == .header || $0.line.reorderable) && $0.line.id != nil }
            .sorted { $0.frame.minY < $1.frame.minY }
        let target = candidates.first { drop.y < $0.frame.midY }
        let before = target?.line.id
        guard before != id else { return }
        ink.act("move:\(id):\(before ?? "end")", ink.rect(view))
        flushPending()
    }

    func reveal(section: String) {
        guard let index = items.firstIndex(where: {
            if case .line(let line) = $0 { return line.id == section }
            return false
        }), index < subviews.count,
        let scroll = enclosingScrollView else { return }
        let target = subviews[index]
        let rect = target.frame
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - SessionInfoMetrics.rowHeight)))
        scroll.reflectScrolledClipView(scroll.contentView)
        target.layer?.backgroundColor = ink.colors.hover.withAlphaComponent(0.8).cgColor
        revealTimer.schedule(after: .milliseconds(350)) { @MainActor [weak target] in
            target?.layer?.backgroundColor = nil
        }
    }

    /// The list's height at `width` with its current items, without moving a view: the panel hugs
    /// it (Leo, 2026-11-02: "IT IS TAKING THIS STUPID FUCKING SPACE FOR NO REASON").
    func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }

    private func place() {
        let height = arrange(width: width, apply: true)
        let changed = abs(frame.height - height) >= 0.5
        setFrameSize(NSSize(width: width, height: height))
        if changed { onHeightChange?() }
    }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var y = SessionInfoMetrics.padding
        let inner = max(0, width - 2 * SessionInfoMetrics.edge)
        for (item, view) in zip(items, subviews) {
            switch item {
            case .title:
                let height: CGFloat
                if let line = view as? SessionInfoLineView {
                    height = line.height(forWidth: inner)
                    if apply { line.frame = CGRect(x: SessionInfoMetrics.edge, y: y, width: inner, height: height) }
                } else {
                    height = (view as? ChromeLabel)?.naturalSize.height ?? 16
                    if apply { view.frame = CGRect(x: SessionInfoMetrics.inset, y: y + 6, width: max(0, width - 2 * SessionInfoMetrics.inset), height: height) }
                }
                y += height + 12
            case .separator:
                y += SessionInfoMetrics.groupGap
                if apply { view.frame = CGRect(x: SessionInfoMetrics.edge, y: y, width: inner, height: 1) }
                y += 1 + SessionInfoMetrics.groupGap
            case .line:
                guard let line = view as? SessionInfoLineView else { continue }
                let height = line.height(forWidth: inner)
                if apply { line.frame = CGRect(x: SessionInfoMetrics.edge, y: y, width: inner, height: height) }
                y += height
            }
        }
        return y + SessionInfoMetrics.padding
    }
}

/// A running row's three-dot wave. The page supplies the index and cadence; Motion only gates
/// whether the supplied loop may run, and Core Animation owns the repeating work.
private final class SessionInfoWaveView: NSView {
    private let dots = CAReplicatorLayer()
    private let dot = CAShapeLayer()
    private var wave: AgentPaneSessionInfoModel.Wave
    private let color: CGColor
    private var motionSubscription: MotionSubscription?
    /// Says when the wave may have come into sight or left it (moved to a window, shown, its
    /// window's occlusion changed). It owns the window observation, so this view has no `deinit`.
    private let visibility = AgentPaneVisibilityProbe(frame: .zero)

    init(wave: AgentPaneSessionInfoModel.Wave, color: NSColor) {
        self.wave = wave
        self.color = color.cgColor
        super.init(frame: .zero)
        wantsLayer = true
        dots.actions = [:]
        dot.actions = [:]
        dots.addSublayer(dot)
        layer?.addSublayer(dots)
        visibility.onChange = { [weak self] in self?.updateAnimation() }
        addSubview(visibility)
        motionSubscription = Motion.changes.subscribe { [weak self] _ in self?.updateAnimation() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        dots.frame = bounds
        dots.instanceCount = 3
        let dotSize: CGFloat = 3
        let gap: CGFloat = 2.5
        dot.frame = CGRect(x: 0, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        dot.fillColor = color
        dots.instanceTransform = CATransform3DMakeTranslation(dotSize + gap, 0, 0)
        updateAnimation()
    }

    func update(wave: AgentPaneSessionInfoModel.Wave, color: NSColor) {
        self.wave = wave
        dot.fillColor = color.cgColor
        updateAnimation()
    }

    private func updateAnimation() {
        guard let dot = dots.sublayers?.first as? CAShapeLayer else { return }
        dot.removeAllAnimations()
        guard window != nil, !isHiddenOrHasHiddenAncestor, window?.occlusionState.contains(.visible) != false,
              Motion.indicators.animatesLoops else {
            dot.opacity = 1
            return
        }
        let period = max(0.001, Double(wave.periodMs) / 1000)
        let step = max(0, Double(wave.stepMs) / 1000)
        let animation = Motion.sampledKeyframes("opacity", values: [0.55, 0.775, 1, 0.775, 0.55, 0.55, 0.55, 0.55, 0.55, 0.55, 0.55], duration: period)
        animation.repeatCount = .infinity
        animation.beginTime = dot.convertTime(SpinnerClock().beginTime(cycle: period) - Double(wave.index) * step, from: nil)
        dots.instanceDelay = step
        dot.add(animation, forKey: "session-info.wave")
    }
}

/// A line of the panel: lights on hover (the line only, never the panel) when it has an action and
/// runs it on a click; its buttons light and run their own.
final class SessionInfoLineView: NSView, NSMenuDelegate {
    override var isFlipped: Bool { true }
    private(set) var line: SessionInfoLine
    private var ink: SessionInfoInk
    private var glyph: NSView?
    private var grip: SessionInfoGripView?
    private let title = ChromeLabel(labelWithString: "")
    private var detail: ChromeLabel?
    private var subtitle: ChromeLabel?
    private var trailing: ChromeLabel?
    private var chevron: NSImageView?
    private var meter: SessionInfoMeterView?
    private var segmentedMeter: SessionInfoSegmentsView?
    private var toggle: NSSwitch?
    private var menuButton: SessionInfoButtonView?
    private var marksView: SessionInfoMarksView?
    private(set) var buttons: [SessionInfoButtonView] = []
    private var hovered = false { didSet { paint() } }
    private var focused = false { didSet { paint() } }
    private(set) var isDragging = false
    private(set) var isMenuOpen = false
    private var dragStart: NSPoint?
    /// The press began on the grip: its click alone does nothing, as the web panel's handle button.
    private var pressedGrip = false

    init(line: SessionInfoLine, ink: SessionInfoInk) {
        self.line = line
        self.ink = ink
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SessionInfoMetrics.rowRadius
        rebuild()
        paint()
    }

    /// Rebuild every value-bearing child from the page model. Rows are keyed by id so this view
    /// survives a model refresh for focus and accessibility, but its children must not retain
    /// values from the previous snapshot (meters, marks, menus and action closures included).
    private func rebuild() {
        let colors = ink.colors
        installGlyph()
        title.stringValue = line.title
        title.font = line.font
        title.lineBreakMode = .byTruncatingTail
        title.textColor = switch line.titleInk {
        case .primary: colors.primary
        case .secondary: colors.secondary
        case .danger: colors.danger
        }
        if let text = line.detail { detail = Self.label(text, font: Typography.body, color: colors.tertiary) }
        if let text = line.subtitle ?? line.progress {
            let label = Self.label(text, font: Typography.caption, color: colors.secondary)
            label.wraps = true
            label.maximumNumberOfLines = 2
            label.truncatesLastVisibleLine = true
            subtitle = label
        }
        if let text = line.trailing {
            let font = line.kind == .row ? NSFont.monospacedDigitSystemFont(ofSize: Typography.caption.pointSize, weight: .regular) : Typography.caption
            trailing = Self.label(text, font: font, color: colors.tone(line.trailingTone))
        }
        if let unfolded = line.unfolded {
            chevron = Self.image(unfolded ? "chevron.down" : "chevron.right", font: Typography.caption, tint: colors.secondary)
        }
        if let values = line.segments, !values.isEmpty { segmentedMeter = SessionInfoSegmentsView(values: values, colors: colors) }
        else if let value = line.meter { meter = SessionInfoMeterView(value: value, colors: colors) }
        if let marks = line.marks, !marks.isEmpty { marksView = SessionInfoMarksView(tones: marks, colors: colors) }
        if let toggle = line.toggle {
            let control = NSSwitch()
            // The row's size, as the web panel's 36x20 switch: never the regular switch, which
            // overflows a 28 row.
            control.controlSize = .small
            control.state = toggle ? .on : .off
            control.target = self
            control.action = #selector(toggleChanged(_:))
            control.themedToolTip = line.help
            self.toggle = control
        }
        if !line.menu.isEmpty {
            menuButton = SessionInfoButtonView(button: .init(label: line.menuLabel ?? line.title, symbol: "ellipsis", action: "__menu__", disabled: false), ink: ink)
            menuButton?.onPress = { [weak self] in self?.showMenu() }
        }
        if line.reorderable {
            let grip = SessionInfoGripView(rest: colors.secondary, lit: colors.primary)
            grip.themedToolTip = line.reorderLabel ?? line.title
            self.grip = grip
        }
        buttons = line.buttons.map { SessionInfoButtonView(button: $0, ink: ink) }
        for view in [glyph, grip, title, detail, subtitle, trailing, chevron, meter, segmentedMeter, marksView, toggle, menuButton].compactMap({ $0 }) + buttons { addSubview(view) }
        themedToolTip = [line.help, line.hover?.title, line.hover?.detail].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityLabel([line.title, line.detail, line.subtitle ?? line.progress, line.trailing].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityRole(line.action != nil ? .button : .staticText)
        if let unfolded = line.unfolded { setAccessibilityExpanded(unfolded) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Where the line's columns land in its own coordinates, for the grid tests: its icon, its
    /// title, its trailing value and its switch.
    var columns: (icon: CGRect?, title: CGRect, trailing: CGRect?, toggle: NSSwitch?) {
        (glyph?.frame, title.frame, trailing?.frame, toggle)
    }

    /// Whether a page refresh changes this row or its theme; handler closures are stable for the
    /// mounted panel and do not participate in equality.
    func matches(line: SessionInfoLine, ink: SessionInfoInk) -> Bool {
        self.line == line && self.ink.colors == ink.colors
    }

    /// Refreshes a keyed native row without leaving any child from the prior page model attached.
    func update(line: SessionInfoLine, ink: SessionInfoInk) {
        self.line = line
        self.ink = ink
        glyph = nil
        grip = nil
        detail = nil
        subtitle = nil
        trailing = nil
        chevron = nil
        meter = nil
        segmentedMeter = nil
        toggle = nil
        menuButton = nil
        marksView = nil
        buttons = []
        isMenuOpen = false
        isDragging = false
        dragStart = nil
        pressedGrip = false
        subviews.forEach { $0.removeFromSuperview() }
        rebuild()
        updateTrackingAreas()
        needsLayout = true
        paint()
    }

    private func installGlyph() {
        glyph?.removeFromSuperview()
        glyph = nil
        let colors = ink.colors
        let identity = colors.identity(line.identityTone)
        if line.working {
            let spinner = StatusIndicatorView.spinner()
            spinner.spinnerColor = identity
            spinner.spin(true)
            glyph = spinner
        } else if let wave = line.wave {
            glyph = SessionInfoWaveView(wave: wave, color: identity ?? colors.secondary)
        } else if let harness = line.harness {
            glyph = Self.image(HarnessSymbolImages.isSymbolName(harness) ? harness : "person.crop.circle", font: Typography.body, tint: identity ?? colors.secondary)
        } else if line.symbol == "terminal.prompt" {
            let prompt = ChromeLabel(labelWithString: ">_")
            prompt.font = Typography.caption
            prompt.textColor = colors.secondary
            prompt.alignment = .center
            glyph = prompt
        } else if line.spins {
            let spinner = StatusIndicatorView.spinner()
            spinner.spin(true)
            glyph = spinner
        } else if let symbol = line.symbol {
            let font = line.discloses ? Typography.caption : Typography.body
            glyph = Self.image(symbol, font: font, tint: identity ?? colors.symbol(line.symbolColor, fallback: line.titleInk == .danger ? colors.danger : colors.secondary))
        }
        if let glyph { addSubview(glyph) }
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> ChromeLabel {
        let label = ChromeLabel(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// `symbol` is an SF Symbol, or `cmux:` and a pack icon name (Changes' `cmux:git.pullrequest.merged`),
    /// which draws the pack's own glyph at the web rows' size (1.2 x the label, design/icons "Sizes").
    private static func image(_ symbol: String, font: NSFont, tint: NSColor) -> NSImageView {
        let view = NSImageView()
        if let icon = packIcon(symbol, font: font) {
            view.image = icon
        } else {
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
        }
        view.contentTintColor = tint
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    static let packPrefix = "cmux:"

    /// The pack's template image for a `cmux:` name the pack has; nil for an SF Symbol name.
    static func packIcon(_ symbol: String, font: NSFont) -> NSImage? {
        guard symbol.hasPrefix(packPrefix) else { return nil }
        let icon = IconName(String(symbol.dropFirst(packPrefix.count)))
        guard IconPack.bundled.drawing(for: icon) != nil else { return nil }
        return NSImage.icon(icon, size: (font.pointSize * 1.2).rounded())
    }

    private var lead: CGFloat { CGFloat(line.indent) * SessionInfoMetrics.indent + SessionInfoMetrics.inset - SessionInfoMetrics.edge }
    /// The title column: the same for a line with an icon and one without, so headers and rows
    /// start their titles on one line. The grip takes no room of its own (it sits at the line's
    /// right edge).
    private var textX: CGFloat { lead + SessionInfoMetrics.iconBox + LayoutGrid.gap }
    /// The six-dot grip shows on hover and while it drags; at rest the line draws no glyph for it.
    var showsGrip: Bool { grip != nil && (hovered || isDragging) }
    /// A foldable header's chevron, after its title, shows on hover and keyboard focus.
    var showsChevron: Bool { chevron != nil && (hovered || focused) }
    /// Where a press grabs the grip: the line's right inset, past the trailing column, full height
    /// (the web panel's `.acpmux-session-info-section__handle`, in the body's right inset).
    var gripHitRect: CGRect? {
        guard grip != nil else { return nil }
        let right = SessionInfoMetrics.trail
        return CGRect(x: bounds.width - right, y: 0, width: right, height: bounds.height)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var height = title.naturalSize.height
        if let subtitle { height += 1 + subtitle.size(forWidth: max(1, textWidth(width))).height }
        if meter != nil || segmentedMeter != nil { height += 6 }
        // A one-line row is the grid's 28; a taller one grows by whole 4 pt steps.
        return max(SessionInfoMetrics.rowHeight, ((height + 12) / LayoutGrid.base).rounded(.up) * LayoutGrid.base)
    }

    private func trailingWidth(_ width: CGFloat) -> CGFloat {
        var used: CGFloat = 0
        for button in buttons { used += button.naturalWidth + 2 }
        if let toggle { used += toggle.intrinsicContentSize.width + 6 }
        if let menuButton { used += menuButton.naturalWidth + 2 }
        if let trailing { used += min(trailing.naturalSize.width, width / 2) + 6 }
        if line.kind == .header, meter != nil || segmentedMeter != nil { used += 36 + 6 }
        return used
    }

    private func textWidth(_ width: CGFloat) -> CGFloat {
        max(0, width - textX - SessionInfoMetrics.trail - trailingWidth(width))
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        var x = width - SessionInfoMetrics.trail
        for button in buttons.reversed() {
            let size = CGSize(width: button.naturalWidth, height: 18)
            x -= size.width
            button.frame = CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            x -= 2
        }
        if let menuButton {
            let w = menuButton.naturalWidth
            x -= w
            menuButton.frame = CGRect(x: x, y: (height - 18) / 2, width: w, height: 18)
            x -= 2
        }
        if let marksView {
            let w: CGFloat = CGFloat(marksView.count) * 8
            x -= w
            marksView.frame = CGRect(x: x, y: (height - 6) / 2, width: w, height: 6)
            x -= 6
        }
        if let toggle {
            let size = toggle.intrinsicContentSize
            x -= size.width
            toggle.frame = CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            x -= 6
        }
        if line.kind == .header, let meter {
            x -= 36
            meter.frame = CGRect(x: x, y: (height - 3) / 2, width: 36, height: 3)
            x -= 6
        }
        if line.kind == .header, let segmentedMeter {
            x -= 36
            segmentedMeter.frame = CGRect(x: x, y: (height - 3) / 2, width: 36, height: 3)
            x -= 6
        }
        if let trailing {
            let size = trailing.naturalSize
            let w = min(size.width, width / 2)
            x -= w
            trailing.frame = CGRect(x: x, y: (height - size.height) / 2, width: w, height: size.height)
            x -= 6
        }
        let textRight = x
        let textWidth = max(0, textRight - textX)
        let titleSize = title.naturalSize
        let subtitleHeight = subtitle.map { $0.size(forWidth: max(1, textWidth)).height } ?? 0
        let block = titleSize.height + (subtitle != nil ? 1 + subtitleHeight : 0) + (line.kind == .row && (meter != nil || segmentedMeter != nil) ? 6 : 0)
        var y = (height - block) / 2
        // The chevron sits one grid gap after the title in a 16pt icon box (the web panel's
        // `.acpmux-session-info-section__fold`). Its room comes off the title's whether or not it
        // shows, so it never runs into the meta or the meter and the title never moves on hover.
        let chevronWidth: CGFloat = chevron != nil ? LayoutGrid.gap + LayoutGrid.iconBox : 0
        let titleWidth = max(0, min(titleSize.width, textWidth - chevronWidth))
        title.frame = CGRect(x: textX, y: y, width: titleWidth, height: titleSize.height)
        var after = textX + titleWidth
        if let chevron {
            chevron.frame = CGRect(x: after + LayoutGrid.gap, y: y + (titleSize.height - LayoutGrid.iconBox) / 2,
                                   width: LayoutGrid.iconBox, height: LayoutGrid.iconBox)
            after += chevronWidth
        }
        if let detail {
            let w = max(0, min(detail.naturalSize.width, textRight - after - 4))
            detail.frame = CGRect(x: after + 4, y: y, width: w, height: titleSize.height)
        }
        if let glyph {
            // Every leading mark centers in the one icon box: a spinner or a chevron at the small
            // glyph size, the wave at its dots' width, any other icon filling the box.
            let box = SessionInfoMetrics.iconBox
            let side: CGFloat = line.working || line.spins || line.discloses ? SessionInfoMetrics.glyph : box
            let inkWidth: CGFloat = line.wave != nil && !line.working ? 14 : side
            glyph.frame = CGRect(x: lead + (box - inkWidth) / 2, y: y + (titleSize.height - side) / 2, width: inkWidth, height: side)
        }
        if let grip, let hit = gripHitRect {
            // Six dots, 6 by 14, centred in the right inset on the title's line.
            let size = SessionInfoGripView.size
            grip.frame = CGRect(x: hit.midX - size.width / 2, y: y + (titleSize.height - size.height) / 2,
                                width: size.width, height: size.height)
        }
        y += titleSize.height
        if let subtitle {
            subtitle.frame = CGRect(x: textX, y: y + 1, width: textWidth, height: subtitleHeight)
            y += 1 + subtitleHeight
        }
        if line.kind == .row, let meter { meter.frame = CGRect(x: textX, y: y + 3, width: textWidth, height: 3) }
        if line.kind == .row, let segmentedMeter { segmentedMeter.frame = CGRect(x: textX, y: y + 3, width: textWidth, height: 3) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // A new area sends no Entered for a pointer already inside it, and then no Exited when the
        // pointer leaves: so the line takes the pointer's place now, and an area made with the pointer
        // inside assumes it, or a line rebuilt under the pointer stays lit at rest.
        // Set only on a change: a repaint here would clear a reveal's highlight as its scroll lands.
        let inside = pointerInside
        if hovered != inside { hovered = inside }
        guard line.action != nil || line.reorderable || !line.menu.isEmpty else { return }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if inside { options.insert(.assumeInside) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
    }

    private var pointerInside: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    // A refresh takes every line out of the list and puts it back: out of the window, a line is never lit.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, hovered { hovered = false }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        focusEnclosingSessionInfoPanel()
        let point = convert(event.locationInWindow, from: nil)
        pressedGrip = line.reorderable && line.id != nil && (gripHitRect?.contains(point) == true)
        dragStart = pressedGrip ? point : nil
        isDragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, line.reorderable, line.id != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !isDragging, hypot(point.x - start.x, point.y - start.y) >= 4 {
            isDragging = true
            paint()
            NSCursor.closedHand.set()
        }
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let onGrip = pressedGrip
        defer { dragStart = nil; pressedGrip = false; isDragging = false; paint() }
        if isDragging, let id = line.id {
            ink.move(id, self, convert(event.locationInWindow, from: nil))
        } else if inside, !onGrip {
            press()
        }
        ink.flush()
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if showsGrip, let hit = gripHitRect { addCursorRect(hit, cursor: isDragging ? .closedHand : .openHand) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // Keyboard focus only (the web's :focus-visible): a click that focuses a header leaves no chevron.
        if accepted, NSApp.isFullKeyboardAccessEnabled { focused = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focused = false }
        return resigned
    }

    override func accessibilityPerformPress() -> Bool { press() }

    // Keyboard: with Full Keyboard Access a line with an action is a key view; Space or Return runs it.
    override var acceptsFirstResponder: Bool { line.action != nil }
    override var canBecomeKeyView: Bool { line.action != nil && NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: SessionInfoMetrics.rowRadius, yRadius: SessionInfoMetrics.rowRadius).fill() }
    override func keyDown(with event: NSEvent) {
        if SessionInfoKeys.presses(event), press() { return }
        super.keyDown(with: event)
    }

    /// Runs the line's action; false when it has none.
    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard let action = line.action else { return }
        ink.act(action, ink.rect(self))
        ink.flush()
    }

    private func showMenu() {
        guard !line.menu.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in line.menu {
            // The row runs the line's own session-info action, the one its buttons run (`ink.act`).
            let action = item.action
            let menuItem = AgentPaneMenuAction.item(item.label, symbol: item.symbol ?? "") { [weak self] in self?.runMenuAction(action) }
            menuItem.image = item.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: item.label) }
            menuItem.isEnabled = item.disabled != true
            menu.addItem(menuItem)
        }
        menu.delegate = self
        isMenuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - 2, y: bounds.minY), in: self)
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        ink.flush()
    }

    private func runMenuAction(_ action: String) {
        ink.act(action, ink.rect(self))
        ink.flush()
    }

    @discardableResult func press() -> Bool {
        guard let action = line.action else { return false }
        ink.act(action, ink.rect(self))
        return true
    }

    /// Only a row lights. A section's header is plain text on the glass, never a fill, hovered or not
    /// (Leo, 2026-11-02: "we still HAVE AN ASININE FUCKIGN BACKGROUND").
    private func paint() {
        layer?.backgroundColor = hovered && line.action != nil && line.kind != .header ? ink.colors.hover.cgColor : nil
        grip?.isHidden = !showsGrip
        grip?.lit = isDragging
        chevron?.isHidden = !showsChevron
        window?.invalidateCursorRects(for: self)
    }
}

/// A section's six-dot drag grip, drawn here as the web panel draws its handle (SessionInfoSection.tsx
/// `GRIP_DOTS`: a 6 by 14 box, dots of radius 0.9 at x 1.25 and 4.75, y 3, 7 and 11). Muted at rest,
/// the text color while it drags.
final class SessionInfoGripView: NSView {
    static let size = CGSize(width: 6, height: 14)
    private let rest: NSColor
    private let litColor: NSColor
    var lit = false { didSet { if lit != oldValue { needsDisplay = true } } }

    init(rest: NSColor, lit: NSColor) {
        self.rest = rest
        self.litColor = lit
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        (lit ? litColor : rest).setFill()
        let radius: CGFloat = 0.9
        for y in [3, 7, 11] as [CGFloat] {
            for x in [1.25, 4.75] as [CGFloat] {
                NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)).fill()
            }
        }
    }
}

/// A button at a line's trailing edge: a symbol or a short label, lit on its own hover.
final class SessionInfoButtonView: NSView {
    let button: AgentPaneSessionInfoModel.Button
    private let ink: SessionInfoInk
    private let content: NSView
    private var hovered = false { didSet { paint() } }
    var onPress: (() -> Void)?
    private var enabled: Bool { button.disabled != true }

    init(button: AgentPaneSessionInfoModel.Button, ink: SessionInfoInk) {
        self.button = button
        self.ink = ink
        let tint = button.disabled == true ? ink.colors.tertiary : ink.colors.secondary
        if let symbol = button.symbol {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.label)?
                .withSymbolConfiguration(.init(pointSize: Typography.caption.pointSize, weight: .regular))
            image.contentTintColor = tint
            content = image
        } else {
            let label = ChromeLabel(labelWithString: button.label)
            label.font = Typography.caption
            label.textColor = tint
            content = label
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        addSubview(content)
        themedToolTip = button.label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(button.label)
        setAccessibilityEnabled(enabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var naturalWidth: CGFloat {
        let inner = (content as? ChromeLabel)?.naturalSize.width ?? 12
        return max(18, inner + 10)
    }

    override func layout() {
        super.layout()
        let size = (content as? ChromeLabel)?.naturalSize ?? CGSize(width: 12, height: 12)
        content.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { focusEnclosingSessionInfoPanel() }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func accessibilityPerformPress() -> Bool { press() }

    // Keyboard: with Full Keyboard Access an enabled button is a key view; Space or Return presses it.
    override var acceptsFirstResponder: Bool { enabled }
    override var canBecomeKeyView: Bool { enabled && NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
    override func keyDown(with event: NSEvent) {
        if SessionInfoKeys.presses(event), press() { return }
        super.keyDown(with: event)
    }

    /// Runs the button's action unless it is disabled.
    @discardableResult func press() -> Bool {
        guard enabled else { return false }
        if let onPress { onPress() } else { ink.act(button.action, ink.rect(self)) }
        return true
    }

    private func paint() {
        layer?.backgroundColor = hovered && enabled ? ink.colors.hover.cgColor : nil
    }
}

final class SessionInfoMarksView: NSView {
    private let tones: [AgentPaneSessionInfoModel.Tone]
    private let colors: AgentPaneSessionInfoColors
    var count: Int { tones.count }

    init(tones: [AgentPaneSessionInfoModel.Tone], colors: AgentPaneSessionInfoColors) {
        self.tones = tones
        self.colors = colors
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        for (index, tone) in tones.enumerated() {
            let rect = CGRect(x: CGFloat(index) * 8 + 1, y: 1, width: 4, height: 4)
            let path = NSBezierPath(ovalIn: rect)
            switch tone {
            case .failed: colors.danger.setFill()
            case .running, .accent: colors.accent.setFill()
            case .done: colors.secondary.setFill()
            case .waiting, .muted: colors.tertiary.setStroke(); path.lineWidth = 1
            }
            if tone == .waiting || tone == .muted { path.stroke() } else { path.fill() }
        }
    }
}

/// A segmented meter used by Context and Usage. The page supplies shares and color tokens;
/// the App only paints the stacked bar.
final class SessionInfoSegmentsView: NSView {
    private let values: [AgentPaneSessionInfoModel.Segment]
    private let colors: AgentPaneSessionInfoColors

    init(values: [AgentPaneSessionInfoModel.Segment], colors: AgentPaneSessionInfoColors) {
        self.values = values
        self.colors = colors
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x = bounds.minX
        let total = values.reduce(0) { $0 + max(0, $1.share) }
        guard total > 0 else { return }
        for value in values {
            let width = bounds.width * CGFloat(max(0, value.share) / total)
            colors.color(for: value.color).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: bounds.minY, width: width, height: bounds.height), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            x += width
        }
    }
}

/// A thin meter: a track in the hover fill and the value in the secondary ink.
final class SessionInfoMeterView: NSView {
    private let fill = CALayer()
    private let value: Double

    init(value: Double, colors: AgentPaneSessionInfoColors) {
        self.value = min(1, max(0, value))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = colors.hover.cgColor
        fill.backgroundColor = colors.secondary.cgColor
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        // motion: allow the fill's frame is set, never animated (layout, not an animation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * value, height: bounds.height)
        CATransaction.commit()
    }
}
