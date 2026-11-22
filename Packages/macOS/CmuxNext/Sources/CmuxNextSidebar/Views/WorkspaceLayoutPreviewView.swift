import AppKit
import CmuxAgentBrands
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextResources

/// The workspace hover card's shaped preview: the shown screen's split layout drawn to scale, each pane a tile listing
/// its tabs (icon, title, and the tab's CPU and memory on the row's trailing edge).
///
/// Leo 2026-11-22: "i have this layout. so. the preview should be able to depict that." and "maybe even fit symbols
/// properly in the initial preview without doing stupid layout shifts now or later to pack relevant useful info densely
/// but elegantly." The geometry comes from Rust (`WorkspacePreviewGeometry`) and depends on the layout and the width
/// only: every number has its slot from the first frame (a dash until the first sample), so a sample changes text,
/// never a frame.
final class WorkspaceLayoutPreviewView: NSView {
    /// How the numbers sit in a row: the gallery's variants.
    enum StatsStyle: String, CaseIterable, Sendable {
        /// CPU and memory as bare numbers ("12%  840M").
        case numbers
        /// The same with a small chip and memory glyph before each.
        case symbols
        /// Memory on every row; CPU only where it is hot, in the attention color.
        case memoryFirst
    }

    /// A row's press: show that tab.
    var onSelect: ((TabID) -> Void)?
    /// Set before `configure`: the slots' widths go into the geometry.
    var statsStyle: StatsStyle = .numbers

    private var geometry: WorkspacePreviewGeometry?
    private var layoutModel: SidebarPaneLayout?
    private var tabsByID: [TabID: SidebarTab] = [:]
    private var usage: [String: ResourceUsage] = [:]
    private var tiles: [Tile] = []

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard let geometry else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        return NSSize(width: geometry.width, height: geometry.height)
    }

    /// Lines for the card's text report (tests, accessibility).
    var reportedLines: [String] { tiles.flatMap(\.reportedLines) }

    /// The preview for `layout` at `width`; false (and nothing drawn) when it is not a split or the rule refuses it.
    @discardableResult
    func configure(_ layout: SidebarPaneLayout?, tabs: [SidebarTab], width: CGFloat) -> Bool {
        tabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let layout, layout.isSplit, width > 0,
              let geometry = WorkspacePreviewGeometry.make(layout, width: Double(width), aspect: 1.6, metrics: Self.metrics(statsStyle))
        else {
            self.geometry = nil
            layoutModel = nil
            rebuild()
            return false
        }
        self.geometry = geometry
        layoutModel = layout
        rebuild()
        return true
    }

    /// The newest sample: each row's numbers change in place.
    func setResources(_ report: ResourceReport?) {
        usage = Dictionary((report?.tabs ?? []).map { ($0.id, $0.usage) }, uniquingKeysWith: { first, _ in first })
        for tile in tiles { tile.setUsage(usage) }
    }

    func applyColors() {
        for tile in tiles { tile.applyColors() }
    }

    private func rebuild() {
        for tile in tiles { tile.removeFromSuperview() }
        tiles = []
        invalidateIntrinsicContentSize()
        guard let geometry, let layoutModel else { return }
        let panes = Dictionary(layoutModel.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for out in geometry.panes {
            guard let pane = panes[out.id] else { continue }
            let rows: [Tile.Row] = out.collapsed ? [Self.row(pane, index: pane.active, tabs: tabsByID)].compactMap { $0 }
                : out.shown.compactMap { Self.row(pane, index: $0, tabs: tabsByID) }
            let tile = Tile(rows: rows, more: out.more, stats: out.stats, style: statsStyle,
                            focused: layoutModel.focused == out.id, collapsed: out.collapsed)
            tile.frame = CGRect(x: out.x, y: out.y, width: out.w, height: out.h)
            tile.onSelect = { [weak self] id in self?.onSelect?(id) }
            tile.setUsage(usage)
            addSubview(tile)
            tiles.append(tile)
        }
        applyColors()
    }

    private static func row(_ pane: SidebarPaneLayout.Pane, index: Int, tabs: [TabID: SidebarTab]) -> Tile.Row? {
        guard index >= 0, index < pane.tabs.count else { return nil }
        let id = pane.tabs[index]
        return Tile.Row(id: id, tab: tabs[id], active: index == pane.active)
    }

    // MARK: Sizes

    static var rowFont: NSFont { Typography.system(.default, size: WorkspaceHoverCardView.tokens.captionSize, weight: .regular) }
    static var activeRowFont: NSFont { Typography.system(.default, size: WorkspaceHoverCardView.tokens.captionSize, weight: TypeScale.emphasis) }
    static var statsFont: NSFont { Typography.system(.monospacedDigit, size: WorkspaceHoverCardView.tokens.captionSize - 1, weight: .regular) }
    static var iconSide: CGFloat { (WorkspaceHoverCardView.tokens.captionSize + 2).rounded() }
    static var rowHeight: CGFloat { (rowFont.ascender - rowFont.descender + rowFont.leading + 3).rounded(.up) }
    static let iconGap: CGFloat = 4
    static let inset: CGFloat = 5
    static let statsGap: CGFloat = 5
    /// The widest each number reads: "100%" and "1.2G" in the stats font, plus the glyph in the symbols style.
    static func cpuSlot(_ style: StatsStyle) -> CGFloat { measure("100%") + (style == .symbols ? glyphSide + 2 : 0) }
    static func memorySlot(_ style: StatsStyle) -> CGFloat { measure("888M") + (style == .symbols ? glyphSide + 2 : 0) }
    static var glyphSide: CGFloat { (statsFont.pointSize).rounded() }

    private static func measure(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: statsFont]).width.rounded(.up)
    }

    static func metrics(_ style: StatsStyle) -> WorkspacePreviewGeometry.Metrics {
        let one = memorySlot(style) + statsGap
        return .init(gap: 4, inset: Double(inset), row: Double(rowHeight), row_gap: 1, min_width: 52,
                     max_height: Double(rowHeight * 4 + 4 * 2 + inset * 2 + 4 + rowHeight * 2),
                     max_rows: 4, stats_both: Double(one + cpuSlot(style) + statsGap), stats_one: Double(one),
                     title_min: 44, icon: Double(iconSide + iconGap))
    }
}

/// One pane of the preview: a rounded tile with its tab rows.
private final class Tile: NSView {
    struct Row {
        var id: TabID
        var tab: SidebarTab?
        var active: Bool
    }

    var onSelect: ((TabID) -> Void)?
    private let rows: [Row]
    private let style: WorkspaceLayoutPreviewView.StatsStyle
    private let stats: WorkspacePreviewGeometry.Stats
    private let focused: Bool
    private var rowViews: [RowView] = []
    private let moreLabel = ChromeLabel(labelWithString: "")

    override var isFlipped: Bool { true }

    init(rows: [Row], more: Int, stats: WorkspacePreviewGeometry.Stats, style: WorkspaceLayoutPreviewView.StatsStyle,
         focused: Bool, collapsed: Bool) {
        self.rows = rows
        self.style = style
        self.stats = stats
        self.focused = focused
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        for row in rows {
            let view = RowView(row: row, stats: stats, style: style)
            view.onPress = { [weak self] in self?.onSelect?(row.id) }
            addSubview(view)
            rowViews.append(view)
        }
        moreLabel.font = WorkspaceLayoutPreviewView.statsFont
        moreLabel.stringValue = more > 0 ? "+\(more)" : ""
        moreLabel.isHidden = more == 0
        addSubview(moreLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var reportedLines: [String] { rowViews.map(\.reportedLine) + (moreLabel.isHidden ? [] : [moreLabel.stringValue]) }

    func setUsage(_ usage: [String: ResourceUsage]) {
        for view in rowViews { view.setUsage(usage[view.row.id.rawValue]) }
    }

    override func layout() {
        super.layout()
        let inset = WorkspaceLayoutPreviewView.inset
        let height = WorkspaceLayoutPreviewView.rowHeight
        var y = inset
        for view in rowViews {
            view.frame = CGRect(x: inset, y: y, width: bounds.width - 2 * inset, height: height)
            y += height + 1
        }
        if !moreLabel.isHidden {
            let size = moreLabel.intrinsicContentSize
            moreLabel.frame = CGRect(x: inset + WorkspaceLayoutPreviewView.iconSide + WorkspaceLayoutPreviewView.iconGap,
                                     y: y + ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
    }

    func applyColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(focused ? 0.07 : 0.04).cgColor
            layer?.borderColor = (focused ? Palette.accent.withAlphaComponent(0.55) : Palette.separator).cgColor
            moreLabel.textColor = Palette.textTertiary
        }
        for view in rowViews { view.applyColors() }
    }
}

/// A tab row: icon, title, and the numbers' fixed slots.
private final class RowView: NSView {
    let row: Tile.Row
    var onPress: (() -> Void)?
    private let stats: WorkspacePreviewGeometry.Stats
    private let style: WorkspaceLayoutPreviewView.StatsStyle
    private let icon = NSImageView()
    private let title = ChromeLabel(labelWithString: "")
    private let cpu = ChromeLabel(labelWithString: "–")
    private let memory = ChromeLabel(labelWithString: "–")
    private let cpuGlyph = NSImageView()
    private let memoryGlyph = NSImageView()
    private var hot = false

    override var isFlipped: Bool { true }

    init(row: Tile.Row, stats: WorkspacePreviewGeometry.Stats, style: WorkspaceLayoutPreviewView.StatsStyle) {
        self.row = row
        self.stats = stats
        self.style = style
        super.init(frame: .zero)
        let side = WorkspaceLayoutPreviewView.iconSide
        icon.imageScaling = .scaleProportionallyDown
        icon.image = Self.image(row.tab, side: side)
        title.font = row.active ? WorkspaceLayoutPreviewView.activeRowFont : WorkspaceLayoutPreviewView.rowFont
        title.lineBreakMode = .byTruncatingTail
        title.stringValue = row.tab?.title ?? ""
        for label in [cpu, memory] {
            label.font = WorkspaceLayoutPreviewView.statsFont
            label.alignment = .right
        }
        let glyph = WorkspaceLayoutPreviewView.glyphSide
        cpuGlyph.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: glyph - 1, weight: .regular))
        memoryGlyph.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: glyph - 1, weight: .regular))
        for view in [icon, title, cpu, memory, cpuGlyph, memoryGlyph] { addSubview(view) }
        let showsCPU = stats == .both
        let showsMemory = stats != .none
        cpu.isHidden = !showsCPU
        memory.isHidden = !showsMemory
        cpuGlyph.isHidden = !showsCPU || style != .symbols
        memoryGlyph.isHidden = !showsMemory || style != .symbols
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var reportedLine: String {
        ([title.stringValue] + [cpu, memory].filter { !$0.isHidden && !$0.stringValue.isEmpty }.map(\.stringValue))
            .joined(separator: " ")
    }

    func setUsage(_ usage: ResourceUsage?) {
        let cpuText = WorkspacePreviewGeometry.cpuText(usage)
        hot = (usage?.cpu ?? 0) >= 1
        // Memory-first shows CPU only while it is hot; its slot stays, so nothing moves when it comes and goes.
        cpu.stringValue = style == .memoryFirst && !hot ? "" : cpuText
        memory.stringValue = WorkspacePreviewGeometry.memoryText(usage)
        applyColors()
    }

    override func layout() {
        super.layout()
        let side = WorkspaceLayoutPreviewView.iconSide
        let h = bounds.height
        icon.frame = CGRect(x: 0, y: ((h - side) / 2).rounded(), width: side, height: side)
        var trailing = bounds.width
        let gap = WorkspaceLayoutPreviewView.statsGap
        let glyph = style == .symbols ? WorkspaceLayoutPreviewView.glyphSide + 2 : 0
        func place(_ label: ChromeLabel, _ image: NSImageView, slot: CGFloat) {
            guard !label.isHidden else { return }
            let height = label.intrinsicContentSize.height
            let numberWidth = slot - glyph
            label.frame = CGRect(x: trailing - numberWidth, y: ((h - height) / 2).rounded(), width: numberWidth, height: height)
            if !image.isHidden {
                let g = WorkspaceLayoutPreviewView.glyphSide
                image.frame = CGRect(x: trailing - slot, y: ((h - g) / 2).rounded(), width: g, height: g)
            }
            trailing -= slot + gap
        }
        place(memory, memoryGlyph, slot: WorkspaceLayoutPreviewView.memorySlot(style))
        place(cpu, cpuGlyph, slot: WorkspaceLayoutPreviewView.cpuSlot(style))
        let x = side + WorkspaceLayoutPreviewView.iconGap
        let height = title.intrinsicContentSize.height
        title.frame = CGRect(x: x, y: ((h - height) / 2).rounded(), width: max(0, trailing - x + (stats == .none ? 0 : gap - 2)), height: height)
    }

    func applyColors() {
        performWithTheme {
            title.textColor = row.active ? Palette.textPrimary : Palette.textSecondary
            icon.contentTintColor = Palette.textSecondary
            cpu.textColor = hot ? Palette.attention : Palette.textTertiary
            memory.textColor = Palette.textTertiary
            cpuGlyph.contentTintColor = hot ? Palette.attention : Palette.textTertiary
            memoryGlyph.contentTintColor = Palette.textTertiary
        }
    }

    /// The tab's mark, as the card's tab rows choose it: a cmux page's own icon, a site's globe, the agent's brand,
    /// else the kind's icon.
    private static func image(_ tab: SidebarTab?, side: CGFloat) -> NSImage? {
        guard let tab else { return NSImage.icon(SidebarTabKind.terminal.icon, size: side) }
        return tab.pageIcon.map { NSImage.icon($0, size: side) }
            ?? (tab.host != nil ? NSImage.icon(symbol: WorkspaceIcon.pagePlaceholderSymbol, size: side) : nil)
            ?? tab.brand.flatMap { AgentBrandCatalog.templateImage(brand: $0, size: side) }
            ?? NSImage.icon(tab.kind.icon, size: side)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}
