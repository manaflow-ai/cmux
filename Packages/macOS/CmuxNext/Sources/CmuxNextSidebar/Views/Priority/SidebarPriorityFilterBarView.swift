import AppKit
import CmuxNextDesign

/// The Priority view's filter chips under its header (`sidebar.priorityView.filters`, the Codex
/// app's activity filters): All, Waiting, Unread and Running, each with how many chats it lists. A
/// click picks one; the App keeps the pick (`SidebarPriorityAction.setFilter`). The picked chip
/// takes the selection fill, the others the hover fill under the pointer.
final class SidebarPriorityFilterBarView: NSView {
    var onAction: ((SidebarPriorityAction) -> Void)?
    private(set) var bar = SidebarPriorityFilterBar(selected: .all)
    let chips: [Chip]

    override init(frame: NSRect) {
        chips = SidebarPriorityFilter.allCases.map { Chip($0) }
        super.init(frame: frame)
        for chip in chips {
            chip.onPress = { [weak self] filter in self?.onAction?(.setFilter(filter)) }
            chip.onStep = { [weak self] chip, step in self?.step(from: chip, by: step) }
            addSubview(chip)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(Strings.priorityTitle)
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

    /// An arrow key on a focused chip: the next chip that way (wrapping, as a radio group does)
    /// takes the focus and is picked.
    func step(from chip: Chip, by step: Int) {
        guard let index = chips.firstIndex(where: { $0 === chip }) else { return }
        let next = chips[(index + step + chips.count) % chips.count]
        _ = FocusRoute(.person, "the person pressed an arrow key on a Priority filter chip").moveKeyboard(in: window, to: next)
        onAction?(.setFilter(next.filter))
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

    /// One filter: its name and count, a click picks it. With keyboard access on (the system's
    /// Keyboard Navigation, as the sidebar's other buttons), Tab focuses it, Space or Return picks
    /// it, and the arrow keys move the pick to the chip beside it.
    final class Chip: NSView {
        let filter: SidebarPriorityFilter
        var onPress: ((SidebarPriorityFilter) -> Void)?
        /// An arrow key: -1 for the chip before, 1 for the one after.
        var onStep: ((Chip, Int) -> Void)?
        private let name = ChromeLabel(labelWithString: "")
        private let count = ChromeLabel(labelWithString: "")
        private(set) var selected = false
        private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
        private(set) var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
        private lazy var keyRepaint = KeyWindowRepaint(self)
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
            setAccessibilityValue(NSNumber(value: selected))
            setAccessibilitySelected(selected)
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
                    layer.borderColor = Palette.focusRing.cgColor
                    layer.borderWidth = KeyWindowRepaint.showsFocus(self, focused: isKeyFocused) ? Metrics.lineWidth(1.5) : 0
                }
            }
        }

        override var acceptsFirstResponder: Bool {
            guard NSApp.isFullKeyboardAccessEnabled else { return false }
            let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
            return !(NSApp.currentEvent.map { mouse.contains($0.type) } ?? false)
        }

        override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            keyRepaint.track()
        }

        override func becomeFirstResponder() -> Bool {
            isKeyFocused = true
            return true
        }

        override func resignFirstResponder() -> Bool {
            isKeyFocused = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            if SidebarUpdateToggle.isActivationKey(event) {
                onPress?(filter)
                return
            }
            switch Self.step(for: event) {
            case let step?: onStep?(self, step)
            case nil: super.keyDown(with: event)
            }
        }

        /// -1 for Left or Up, 1 for Right or Down, with no modifier but the arrow keys' own.
        static func step(for event: NSEvent) -> Int? {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
            guard modifiers.isEmpty else { return nil }
            switch event.specialKey {
            case .leftArrow?, .upArrow?: return -1
            case .rightArrow?, .downArrow?: return 1
            default: return nil
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
