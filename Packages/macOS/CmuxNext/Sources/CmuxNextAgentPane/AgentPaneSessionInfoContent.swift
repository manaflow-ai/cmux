import AppKit
import CmuxNextDesign

/// What a section or row needs from the panel: its colors and how a click reaches the page. A value,
/// not the store, so a row holds no reference to it.
struct SessionInfoInk {
    let colors: AgentPaneSessionInfoColors
    let act: (String, CGRect?) -> Void
    let rect: (NSView) -> CGRect?
    let move: (String, NSView, NSPoint) -> Void = { _, _, _ in }
    let flush: () -> Void

    init(colors: AgentPaneSessionInfoColors, act: @escaping (String, CGRect?) -> Void, rect: @escaping (NSView) -> CGRect?, move: @escaping (String, NSView, NSPoint) -> Void = { _, _, _ in }, flush: @escaping () -> Void = {}) {
        self.colors = colors
        self.act = act
        self.rect = rect
        self.move = move
        self.flush = flush
    }
}

enum SessionInfoMetrics {
    static let inset: CGFloat = 10
    static let rowHeight: CGFloat = 26
    static let rowRadius: CGFloat = 6
    static let indent: CGFloat = 14
    static let glyph: CGFloat = 14
    static let groupGap: CGFloat = 8
    static let edge: CGFloat = 4
    static let padding: CGFloat = 6
}

/// One line of the panel, as values: a section's title row, a row, or a section's "View all".
struct SessionInfoLine: Equatable {
    enum Kind: Equatable { case title, header, row, more }
    var id: String?
    var kind: Kind
    var symbol: String?
    var symbolColor: String?
    var harness: String?
    var spins = false
    var title: String
    var titleInk: Ink = .primary
    var detail: String?
    var subtitle: String?
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

    var font: NSFont {
        switch kind {
        case .title: Typography.bodyEmphasized
        case .header: Typography.header
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
                    id: section.bare == true && index == 0 ? section.id : "row:\(section.id):\(row.id)", kind: .row, symbol: row.symbol, symbolColor: row.symbolColor, harness: row.harness,
                    spins: row.tone == .running, title: row.title,
                    titleInk: row.tone == .failed ? .danger : .primary, detail: row.detail, subtitle: row.subtitle,
                    trailing: row.trailing, trailingTone: row.tone, meter: row.meter, segments: row.segments, buttons: row.buttons ?? [],
                    menu: row.menu ?? [], menuLabel: row.menuLabel, reorderLabel: section.reorderLabel, toggle: row.toggle, reorderable: section.bare == true && index == 0 && section.reorderable == true,
                    hover: row.hover, marks: row.marks, indent: min(3, max(0, row.indent ?? 0)), action: row.action, help: row.help)))
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
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = list
        SystemScrollers.followThin(scroll)
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
        if let reveal = store.info?.reveal, reveal.at != lastRevealToken {
            lastRevealToken = reveal.at
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
    var width: CGFloat = 0 { didSet { if width != oldValue { place() } } }

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
                        old.update(line: line, ink: ink)
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
                    old.update(line: value, ink: ink)
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
        let target = subviews[index] as? NSView,
        let scroll = enclosingScrollView else { return }
        let rect = target.frame
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - SessionInfoMetrics.rowHeight)))
        scroll.reflectScrolledClipView(scroll.contentView)
        target.layer?.backgroundColor = ink.colors.hover.withAlphaComponent(0.8).cgColor
        Task { @MainActor [weak target] in target?.layer?.backgroundColor = nil }
    }

    private func place() {
        var y = SessionInfoMetrics.padding
        let inner = max(0, width - 2 * SessionInfoMetrics.edge)
        for (item, view) in zip(items, subviews) {
            switch item {
            case .title:
                let height: CGFloat
                if let line = view as? SessionInfoLineView {
                    height = line.height(forWidth: inner)
                    line.frame = CGRect(x: SessionInfoMetrics.edge, y: y, width: inner, height: height)
                } else {
                    height = (view as? ChromeLabel)?.naturalSize.height ?? 16
                    view.frame = CGRect(x: SessionInfoMetrics.inset, y: y + 6, width: max(0, width - 2 * SessionInfoMetrics.inset), height: height)
                }
                y += height + 12
            case .separator:
                y += SessionInfoMetrics.groupGap
                view.frame = CGRect(x: SessionInfoMetrics.inset, y: y, width: max(0, width - 2 * SessionInfoMetrics.inset), height: 1)
                y += 1 + SessionInfoMetrics.groupGap
            case .line:
                guard let line = view as? SessionInfoLineView else { continue }
                let height = line.height(forWidth: inner)
                line.frame = CGRect(x: SessionInfoMetrics.edge, y: y, width: inner, height: height)
                y += height
            }
        }
        setFrameSize(NSSize(width: width, height: y + SessionInfoMetrics.padding))
    }
}

/// A line of the panel: lights on hover (the line only, never the panel) when it has an action and
/// runs it on a click; its buttons light and run their own.
final class SessionInfoLineView: NSView, NSMenuDelegate {
    override var isFlipped: Bool { true }
    private(set) var line: SessionInfoLine
    private var ink: SessionInfoInk
    private var glyph: NSView?
    private var grip: NSImageView?
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
    private(set) var isDragging = false
    private(set) var isMenuOpen = false
    private var dragStart: NSPoint?

    init(line: SessionInfoLine, ink: SessionInfoInk) {
        self.line = line
        self.ink = ink
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SessionInfoMetrics.rowRadius
        let colors = ink.colors
        if let harness = line.harness {
            glyph = Self.image(HarnessSymbolImages.isSymbolName(harness) ? harness : "person.crop.circle", font: Typography.body, tint: colors.secondary)
        } else if line.symbol == "terminal.prompt" {
            let prompt = ChromeLabel(labelWithString: ">_")
            prompt.font = Typography.caption
            prompt.textColor = colors.secondary
            glyph = prompt
        } else if line.spins {
            let spinner = StatusIndicatorView.spinner()
            spinner.spin(true)
            glyph = spinner
        } else if let symbol = line.symbol {
            glyph = Self.image(symbol, font: Typography.body, tint: colors.symbol(line.symbolColor, fallback: line.titleInk == .danger ? colors.danger : colors.secondary))
        }
        title.stringValue = line.title
        title.font = line.font
        title.lineBreakMode = .byTruncatingTail
        title.textColor = switch line.titleInk {
        case .primary: colors.primary
        case .secondary: colors.secondary
        case .danger: colors.danger
        }
        if let text = line.detail { detail = Self.label(text, font: Typography.body, color: colors.tertiary) }
        if let text = line.subtitle {
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
            chevron = Self.image(unfolded ? "chevron.down" : "chevron.right", font: Typography.caption, tint: colors.tertiary)
        }
        if let values = line.segments, !values.isEmpty { segmentedMeter = SessionInfoSegmentsView(values: values, colors: colors) }
        else if let value = line.meter { meter = SessionInfoMeterView(value: value, colors: colors) }
        if let marks = line.marks, !marks.isEmpty { marksView = SessionInfoMarksView(tones: marks, colors: colors) }
        if let toggle = line.toggle {
            let control = NSSwitch()
            control.state = toggle ? .on : .off
            control.target = self
            control.action = #selector(toggleChanged(_:))
            control.toolTip = line.help
            self.toggle = control
        }
        if !line.menu.isEmpty {
            menuButton = SessionInfoButtonView(button: .init(label: line.menuLabel ?? line.title, symbol: "ellipsis", action: "__menu__", disabled: false), ink: ink)
            menuButton?.onPress = { [weak self] in self?.showMenu() }
        }
        if line.reorderable {
            grip = Self.image("line.3.horizontal", font: Typography.caption, tint: colors.tertiary)
            grip?.toolTip = line.reorderLabel ?? line.title
        }
        buttons = line.buttons.map { SessionInfoButtonView(button: $0, ink: ink) }
        for view in [glyph, grip, title, detail, subtitle, trailing, chevron, meter, segmentedMeter, marksView, toggle, menuButton].compactMap({ $0 }) + buttons { addSubview(view) }
        toolTip = [line.help, line.hover?.title, line.hover?.detail].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityLabel([line.title, line.detail, line.trailing].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityRole(line.action != nil ? .button : .staticText)
        if let unfolded = line.unfolded { setAccessibilityExpanded(unfolded) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Refreshes the values a page can stream without replacing the native row. The list keeps
    /// this view keyed by `line.id`, so focus and hover survive a live label update.
    func update(line: SessionInfoLine, ink: SessionInfoInk) {
        self.line = line
        self.ink = ink
        title.stringValue = line.title
        title.font = line.font
        title.textColor = switch line.titleInk {
        case .primary: ink.colors.primary
        case .secondary: ink.colors.secondary
        case .danger: ink.colors.danger
        }
        if let text = line.trailing {
            if let trailing {
                trailing.stringValue = text
                trailing.textColor = ink.colors.tone(line.trailingTone)
            } else {
                let label = Self.label(text, font: line.kind == .row ? NSFont.monospacedDigitSystemFont(ofSize: Typography.caption.pointSize, weight: .regular) : Typography.caption, color: ink.colors.tone(line.trailingTone))
                trailing = label
                addSubview(label)
            }
        } else if let trailing {
            trailing.removeFromSuperview()
            self.trailing = nil
        }
        if let unfolded = line.unfolded {
            let symbol = unfolded ? "chevron.down" : "chevron.right"
            if let chevron {
                chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: Typography.caption.pointSize, weight: .regular))
                chevron.contentTintColor = ink.colors.tertiary
            } else {
                let view = Self.image(symbol, font: Typography.caption, tint: ink.colors.tertiary)
                chevron = view
                addSubview(view)
            }
        } else if let chevron {
            chevron.removeFromSuperview()
            self.chevron = nil
        }
        if let detailText = line.detail {
            if let detail {
                detail.stringValue = detailText
                detail.textColor = ink.colors.tertiary
            } else {
                let label = Self.label(detailText, font: Typography.body, color: ink.colors.tertiary)
                detail = label
                addSubview(label)
            }
        } else if let detail {
            detail.removeFromSuperview()
            self.detail = nil
        }
        if let value = line.toggle {
            if let toggle {
                toggle.state = value ? .on : .off
                toggle.toolTip = line.help
            } else {
                let control = NSSwitch()
                control.state = value ? .on : .off
                control.target = self
                control.action = #selector(toggleChanged(_:))
                control.toolTip = line.help
                toggle = control
                addSubview(control)
            }
        } else if let toggle {
            toggle.removeFromSuperview()
            self.toggle = nil
        }
        setAccessibilityLabel([line.title, line.detail, line.trailing].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityRole(line.action != nil ? .button : .staticText)
        if let unfolded = line.unfolded { setAccessibilityExpanded(unfolded) }
        needsLayout = true
        paint()
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> ChromeLabel {
        let label = ChromeLabel(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func image(_ symbol: String, font: NSFont, tint: NSColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
        view.contentTintColor = tint
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    private var lead: CGFloat { CGFloat(line.indent) * SessionInfoMetrics.indent + SessionInfoMetrics.inset - SessionInfoMetrics.edge }
    private var textX: CGFloat { lead + (grip != nil ? 14 : 0) + (glyph != nil ? SessionInfoMetrics.glyph + 6 : 0) }

    func height(forWidth width: CGFloat) -> CGFloat {
        var height = title.naturalSize.height
        if let subtitle { height += 1 + subtitle.size(forWidth: max(1, textWidth(width))).height }
        if meter != nil || segmentedMeter != nil { height += 6 }
        return max(SessionInfoMetrics.rowHeight, height + 10)
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
        max(0, width - textX - (SessionInfoMetrics.inset - SessionInfoMetrics.edge) - trailingWidth(width))
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let right = SessionInfoMetrics.inset - SessionInfoMetrics.edge
        var x = width - right
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
        // The chevron's room comes off the title's, so it never runs into the meta or the meter.
        let chevronWidth: CGFloat = chevron != nil ? 16 : 0
        let titleWidth = max(0, min(titleSize.width, textWidth - chevronWidth))
        title.frame = CGRect(x: textX, y: y, width: titleWidth, height: titleSize.height)
        var after = textX + titleWidth
        if let chevron {
            chevron.frame = CGRect(x: after + 6, y: y, width: 10, height: titleSize.height)
            after += chevronWidth
        }
        if let detail {
            let w = max(0, min(detail.naturalSize.width, textRight - after - 4))
            detail.frame = CGRect(x: after + 4, y: y, width: w, height: titleSize.height)
        }
        if let glyph {
            let side: CGFloat = line.spins ? 10 : SessionInfoMetrics.glyph
            glyph.frame = CGRect(x: lead + (SessionInfoMetrics.glyph - side) / 2, y: y + (titleSize.height - side) / 2, width: side, height: side)
        }
        if let grip {
            let side: CGFloat = 12
            grip.frame = CGRect(x: max(0, lead - 6), y: y + (titleSize.height - side) / 2, width: side, height: side)
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
        guard line.action != nil || line.reorderable || !line.menu.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = line.reorderable && line.id != nil && (grip?.frame.contains(point) == true) ? point : nil
        isDragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, line.reorderable, line.id != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - start.x, point.y - start.y) >= 4 { isDragging = true }
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        defer { dragStart = nil; isDragging = false }
        if isDragging, let id = line.id {
            ink.move(id, self, convert(event.locationInWindow, from: nil))
        } else if inside {
            press()
        }
        ink.flush()
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
            let menuItem = NSMenuItem(title: item.label, action: #selector(menuItemPressed(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.action
            menuItem.isEnabled = item.disabled != true
            if let symbol = item.symbol {
                menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
            }
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

    @objc private func menuItemPressed(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        ink.act(action, ink.rect(self))
        ink.flush()
    }

    @discardableResult func press() -> Bool {
        guard let action = line.action else { return false }
        ink.act(action, ink.rect(self))
        return true
    }

    private func paint() {
        layer?.backgroundColor = hovered && line.action != nil ? ink.colors.hover.cgColor : nil
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
        toolTip = button.label
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
    override func mouseDown(with event: NSEvent) {}
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
