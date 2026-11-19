import AppKit
import CmuxNextDesign

/// The Priority view's filter chips under its header (`sidebar.priorityView.filters`, the Codex
/// app's activity filters): All, Waiting, Unread and Running, each with how many chats it lists. A
/// click picks one; the App keeps the pick (`SidebarPriorityAction.setFilter`). The picked chip
/// takes the selection fill, the others the hover fill under the pointer.
final class SidebarPriorityFilterBarView: NSView {
    var onAction: ((SidebarPriorityAction) -> Void)?
    private(set) var bar = SidebarPriorityFilterBar(selected: .all)
    private(set) var chips: [Chip] = SidebarPriorityFilter.allCases.map(Chip.init)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for chip in chips {
            chip.onPress = { [weak self] filter in self?.onAction?(.setFilter(filter)) }
            addSubview(chip)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// The bar's height: one line of chip text and its padding.
    static var height: CGFloat { ceil(SidebarStyle.subtitleFont.boundingRectForFont.height) + Metrics.space2 * 2 }

    func show(_ bar: SidebarPriorityFilterBar) {
        guard bar != self.bar else { return }
        self.bar = bar
        for chip in chips { chip.configure(count: bar.count(chip.filter), selected: bar.selected == chip.filter) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = SidebarStyle.horizontalInset
        let chipHeight = ceil(SidebarStyle.subtitleFont.boundingRectForFont.height) + Metrics.space1 * 2
        var x = inset
        let y = (bounds.height - chipHeight) / 2
        // Natural widths when they fit, else each chip gets an equal share of the row.
        let natural = chips.map(\.naturalWidth)
        let room = max(0, bounds.width - inset * 2 - Metrics.space1 * CGFloat(chips.count - 1))
        let fits = natural.reduce(0, +) <= room
        for (chip, width) in zip(chips, natural) {
            let w = fits ? width : room / CGFloat(chips.count)
            chip.frame = NSRect(x: x, y: y, width: w, height: chipHeight)
            x += w + Metrics.space1
        }
    }

    /// One filter: its name and count, a click picks it.
    final class Chip: NSView {
        let filter: SidebarPriorityFilter
        var onPress: ((SidebarPriorityFilter) -> Void)?
        private let name = ChromeLabel(labelWithString: "")
        private let count = ChromeLabel(labelWithString: "")
        private(set) var selected = false
        private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
        private var pointerHover: PointerHover?

        init(_ filter: SidebarPriorityFilter) {
            self.filter = filter
            super.init(frame: .zero)
            wantsLayer = true
            name.stringValue = Self.title(filter)
            [name, count].forEach(addSubview)
            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            pointerHover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
            configure(count: 0, selected: filter == .all)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        nonisolated override var isFlipped: Bool { true }
        nonisolated override var wantsUpdateLayer: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        static func title(_ filter: SidebarPriorityFilter) -> String {
            switch filter {
            case .all: Strings.priorityFilterAll
            case .waiting: Strings.priorityFilterWaiting
            case .unread: Strings.priorityFilterUnread
            case .running: Strings.priorityFilterRunning
            }
        }

        var countText: String { count.stringValue }

        func configure(count value: Int, selected: Bool) {
            count.stringValue = String(value)
            self.selected = selected
            setAccessibilityLabel([Self.title(filter), String(value)].joined(separator: ", "))
            setAccessibilityValue(selected)
            needsLayout = true
            needsDisplay = true
        }

        var naturalWidth: CGFloat {
            name.font = SidebarStyle.subtitleFont
            count.font = SidebarStyle.badgeFont
            return ceil(name.naturalSize.width + Metrics.space1 + count.naturalSize.width) + Metrics.space2 * 2
        }

        override func layout() {
            super.layout()
            name.font = SidebarStyle.subtitleFont
            count.font = SidebarStyle.badgeFont
            let nameSize = name.naturalSize, countSize = count.naturalSize
            let content = nameSize.width + Metrics.space1 + countSize.width
            // Centred; a narrow chip truncates its name and keeps the count.
            let x = max(Metrics.space2, (bounds.width - content) / 2)
            let nameWidth = max(0, min(nameSize.width, bounds.width - Metrics.space2 * 2 - Metrics.space1 - countSize.width))
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: x, y: (bounds.height - nameSize.height) / 2, width: nameWidth, height: nameSize.height)
            count.frame = NSRect(x: name.frame.maxX + Metrics.space1, y: (bounds.height - countSize.height) / 2,
                                 width: countSize.width, height: countSize.height)
        }

        override func updateLayer() {
            performWithTheme {
                name.textColor = selected ? Palette.textPrimary : Palette.textSecondary
                count.textColor = filter == .waiting && count.stringValue != "0" ? Palette.attention : Palette.textTertiary
                if let layer {
                    layer.cornerRadius = bounds.height / 2
                    ChromeHover.paint(layer, selected ? Palette.selectionFill : isHovered ? Palette.hoverFill : nil, animated: window != nil)
                }
            }
        }

        /// The press is the chip's own (it picks on release), not the sidebar's below.
        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onPress?(filter)
        }

        override func accessibilityPerformPress() -> Bool {
            onPress?(filter)
            return true
        }
    }
}
