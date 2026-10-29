import AppKit
import CmuxNextDesign

/// What a section or row needs from the panel: its colors and how a click reaches the page. A value,
/// not the store, so a row holds no reference to it.
struct SessionInfoInk {
    let colors: AgentPaneSessionInfoColors
    let act: (String) -> Void
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
    enum Kind: Equatable { case header, row, more }
    var kind: Kind
    var symbol: String?
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
    var buttons: [AgentPaneSessionInfoModel.Button] = []
    var indent = 0
    var action: String?
    var help: String?

    enum Ink: Equatable { case primary, secondary, danger }

    var font: NSFont {
        switch kind {
        case .header: Typography.header
        case .row: Typography.body
        case .more: Typography.caption
        }
    }
}

/// One item of the panel's list.
enum SessionInfoItem: Equatable {
    case title(String)
    case separator
    case line(SessionInfoLine)
}

extension AgentPaneSessionInfoModel {
    /// The panel's list: its title, then each group's sections (where it runs, what it made, what
    /// it runs) with a hairline between groups.
    var items: [SessionInfoItem] {
        var items: [SessionInfoItem] = []
        if let title { items.append(.title(title)) }
        var group: String?
        for section in sections {
            if let group, group != section.group { items.append(.separator) }
            group = section.group
            let bare = section.bare == true
            if !bare {
                items.append(.line(SessionInfoLine(
                    kind: .header, symbol: section.symbol, title: section.title, trailing: section.meta,
                    trailingTone: section.metaTone, unfolded: section.foldable ? section.open : nil, meter: section.meter,
                    action: section.foldable ? "fold:\(section.id):\(section.open ? 0 : 1)" : nil)))
            }
            guard section.open || bare else { continue }
            for row in section.rows {
                items.append(.line(SessionInfoLine(
                    kind: .row, symbol: row.symbol, spins: row.tone == .running, title: row.title,
                    titleInk: row.tone == .failed ? .danger : .primary, detail: row.detail, subtitle: row.subtitle,
                    trailing: row.trailing, trailingTone: row.tone, meter: row.meter, buttons: row.buttons ?? [],
                    indent: min(3, max(0, row.indent ?? 0)), action: row.action, help: row.help)))
            }
            if let more = section.more {
                items.append(.line(SessionInfoLine(kind: .more, title: more.label, titleInk: .secondary, action: more.action)))
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
    private weak var store: AgentPaneSessionInfoStore?

    init(store: AgentPaneSessionInfoStore) {
        self.store = store
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = list
        SystemScrollers.followThin(scroll)
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
    }

    /// The list's views, for tests.
    var lines: [SessionInfoLineView] { list.subviews.compactMap { $0 as? SessionInfoLineView } }

    private func reload() {
        guard let store else { return }
        let act = store.act
        list.show(store.info?.items ?? [], ink: SessionInfoInk(colors: store.colors, act: act))
        list.width = scroll.contentSize.width
    }
}

/// The list's document view: its items laid out top down at the scroll view's width.
final class SessionInfoListView: NSView {
    override var isFlipped: Bool { true }
    private var items: [SessionInfoItem] = []
    private var ink = SessionInfoInk(colors: AgentPaneSessionInfoColors(), act: { _ in })
    var width: CGFloat = 0 { didSet { if width != oldValue { place() } } }

    func show(_ items: [SessionInfoItem], ink: SessionInfoInk) {
        self.items = items
        self.ink = ink
        subviews.forEach { $0.removeFromSuperview() }
        for item in items {
            switch item {
            case .title(let title):
                let label = ChromeLabel(labelWithString: title)
                label.font = Typography.bodyEmphasized
                label.textColor = ink.colors.primary
                label.lineBreakMode = .byTruncatingTail
                addSubview(label)
            case .separator:
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = ink.colors.separator.cgColor
                addSubview(line)
            case .line(let value):
                addSubview(SessionInfoLineView(line: value, ink: ink))
            }
        }
        place()
    }

    private func place() {
        var y = SessionInfoMetrics.padding
        let inner = max(0, width - 2 * SessionInfoMetrics.edge)
        for (item, view) in zip(items, subviews) {
            switch item {
            case .title:
                let height = (view as? ChromeLabel)?.naturalSize.height ?? 16
                view.frame = CGRect(x: SessionInfoMetrics.inset, y: y + 6, width: max(0, width - 2 * SessionInfoMetrics.inset), height: height)
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
final class SessionInfoLineView: NSView {
    override var isFlipped: Bool { true }
    let line: SessionInfoLine
    private let ink: SessionInfoInk
    private var glyph: NSView?
    private let title = ChromeLabel(labelWithString: "")
    private var detail: ChromeLabel?
    private var subtitle: ChromeLabel?
    private var trailing: ChromeLabel?
    private var chevron: NSImageView?
    private var meter: SessionInfoMeterView?
    private(set) var buttons: [SessionInfoButtonView] = []
    private var hovered = false { didSet { paint() } }

    init(line: SessionInfoLine, ink: SessionInfoInk) {
        self.line = line
        self.ink = ink
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SessionInfoMetrics.rowRadius
        let colors = ink.colors
        if line.spins {
            let spinner = StatusIndicatorView.spinner()
            spinner.spin(true)
            glyph = spinner
        } else if let symbol = line.symbol {
            glyph = Self.image(symbol, font: Typography.body, tint: line.titleInk == .danger ? colors.danger : colors.secondary)
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
        if let value = line.meter { meter = SessionInfoMeterView(value: value, colors: colors) }
        buttons = line.buttons.map { SessionInfoButtonView(button: $0, ink: ink) }
        for view in [glyph, title, detail, subtitle, trailing, chevron, meter].compactMap({ $0 }) + buttons { addSubview(view) }
        toolTip = line.help
        setAccessibilityElement(true)
        setAccessibilityLabel([line.title, line.detail, line.trailing].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityRole(line.action != nil ? .button : .staticText)
        if let unfolded = line.unfolded { setAccessibilityExpanded(unfolded) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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
    private var textX: CGFloat { lead + (glyph != nil ? SessionInfoMetrics.glyph + 6 : 0) }

    func height(forWidth width: CGFloat) -> CGFloat {
        var height = title.naturalSize.height
        if let subtitle { height += 1 + subtitle.size(forWidth: max(1, textWidth(width))).height }
        if meter != nil { height += 6 }
        return max(SessionInfoMetrics.rowHeight, height + 10)
    }

    private func trailingWidth(_ width: CGFloat) -> CGFloat {
        var used: CGFloat = 0
        for button in buttons { used += button.naturalWidth + 2 }
        if let trailing { used += min(trailing.naturalSize.width, width / 2) + 6 }
        if line.kind == .header, meter != nil { used += 36 + 6 }
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
        if line.kind == .header, let meter {
            x -= 36
            meter.frame = CGRect(x: x, y: (height - 3) / 2, width: 36, height: 3)
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
        let block = titleSize.height + (subtitle != nil ? 1 + subtitleHeight : 0) + (line.kind == .row && meter != nil ? 6 : 0)
        var y = (height - block) / 2
        let titleWidth = min(titleSize.width, textWidth)
        title.frame = CGRect(x: textX, y: y, width: titleWidth, height: titleSize.height)
        var after = textX + titleWidth
        if let chevron {
            chevron.frame = CGRect(x: after + 6, y: y, width: 10, height: titleSize.height)
            after += 16
        }
        if let detail {
            let w = max(0, min(detail.naturalSize.width, textRight - after - 4))
            detail.frame = CGRect(x: after + 4, y: y, width: w, height: titleSize.height)
        }
        if let glyph {
            let side: CGFloat = line.spins ? 10 : SessionInfoMetrics.glyph
            glyph.frame = CGRect(x: lead + (SessionInfoMetrics.glyph - side) / 2, y: y + (titleSize.height - side) / 2, width: side, height: side)
        }
        y += titleSize.height
        if let subtitle {
            subtitle.frame = CGRect(x: textX, y: y + 1, width: textWidth, height: subtitleHeight)
            y += 1 + subtitleHeight
        }
        if line.kind == .row, let meter { meter.frame = CGRect(x: textX, y: y + 3, width: textWidth, height: 3) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard line.action != nil else { return }
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

    /// Runs the line's action; false when it has none.
    @discardableResult func press() -> Bool {
        guard let action = line.action else { return false }
        ink.act(action)
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

    /// Runs the button's action unless it is disabled.
    @discardableResult func press() -> Bool {
        guard enabled else { return false }
        ink.act(button.action)
        return true
    }

    private func paint() {
        layer?.backgroundColor = hovered && enabled ? ink.colors.hover.cgColor : nil
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
