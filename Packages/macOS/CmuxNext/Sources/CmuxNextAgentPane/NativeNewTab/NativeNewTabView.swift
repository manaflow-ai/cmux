public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The native New Tab page (Lawrence 2026-10-29: "make the new tab page in swift"): a field, the
/// Terminal | Browser | Agent switch and the dropdown under it, with no web view.
///
/// An alternative to the web page while `tabs.nativeNewTabPage` is on. AppKit
/// (plans/cmux-next/no-swiftui-DESIGN.md): the field is made with the page, so the pane can give it
/// the keyboard at once. Rows come from ``NativeNewTabModel/rows`` as values; the view keeps no
/// state but its row views.
public final class NativeNewTabView: NSView, NSTextFieldDelegate {
    /// The page's model: a prepared page adopts a tab's context through it.
    public let model: NativeNewTabModel
    private let strings = NativeNewTabStrings()
    private let kinds = NSSegmentedControl()
    private let card = NSView()
    private let glass = NSImageView()
    private let field = NSTextField()
    private let divider = NSBox()
    private var rowViews: [NativeNewTabRowView] = []
    private var shownRows: [NativeNewTabRow] = []
    // task-owner: the page's `following`, started when it joins a window and cancelled when it leaves.
    private var following: Task<Void, Never>?

    /// The field's height.
    static let fieldHeight: CGFloat = 44
    /// The card's widest width.
    static let maxCardWidth: CGFloat = 640
    /// The most room above the switch.
    static let maxTopGap: CGFloat = 120

    /// Creates the page over `model`.
    /// - Parameter model: The page's state.
    public init(model: NativeNewTabModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        build()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The page for a pane tab.
    public static func hosted(_ model: NativeNewTabModel) -> NativeNewTabHostingView {
        let host = NativeNewTabHostingView(model: model)
        host.setAccessibilityIdentifier("cmux.nativeNewTab")
        return host
    }

    /// The page's text field, the view the pane gives the keyboard to.
    public var fieldView: NSTextField { field }

    /// The dropdown's row views, top to bottom.
    var rows: [NativeNewTabRowView] { Array(rowViews.prefix(shownRows.count)) }

    /// The Terminal | Browser | Agent switch.
    var kindControl: NSSegmentedControl { kinds }

    private func build() {
        // The pane paints under a page (``Palette/paneFill``): the page's own layer paints nothing.
        wantsLayer = true

        kinds.segmentStyle = .automatic
        kinds.trackingMode = .selectOne
        kinds.segmentCount = AgentPaneTabKind.allCases.count
        for (index, kind) in AgentPaneTabKind.allCases.enumerated() {
            kinds.setLabel(strings.title(kind), forSegment: index)
        }
        kinds.target = self
        kinds.action = #selector(kindChanged)
        kinds.setAccessibilityIdentifier("cmux.nativeNewTab.kind")

        card.wantsLayer = true
        card.layer?.cornerRadius = Metrics.surfaceCornerRadius
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = true

        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.contentTintColor = .secondaryLabelColor
        glass.imageScaling = .scaleProportionallyDown

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = strings.placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityIdentifier("cmux.nativeNewTab.field")

        divider.boxType = .separator

        for view in [glass, field, divider] as [NSView] { card.addSubview(view) }
        addSubview(kinds)
        addSubview(card)
        updateColors()
    }

    // MARK: Model

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        following?.cancel()
        following = nil
        guard window != nil else { return }
        updateColors()
        // The page may have been adopted while out of a window: catch up, then follow the model.
        render()
        let model = model
        following = Task { [weak self] in
            for await _ in ObservationStream({ _ = model.rows; _ = model.selectedIndex; _ = model.kind; _ = model.text }) {
                guard let self, !Task.isCancelled else { return }
                self.render()
            }
        }
    }

    /// Reads the model: the switch, the field's text (when the model changed it) and the rows.
    func render() {
        if let index = AgentPaneTabKind.allCases.firstIndex(of: model.kind), kinds.selectedSegment != index {
            kinds.selectedSegment = index
        }
        if field.stringValue != model.text { field.stringValue = model.text }
        field.font = Typography.search
        let rows = model.rows
        let selected = model.selectedIndex
        while rowViews.count < rows.count {
            let row = NativeNewTabRowView(frame: .zero)
            rowViews.append(row)
            card.addSubview(row)
        }
        for (index, view) in rowViews.enumerated() {
            guard index < rows.count else {
                view.isHidden = true
                continue
            }
            let row = rows[index]
            view.isHidden = false
            view.show(NativeNewTabRowContent(row, strings: strings), selected: index == selected)
            view.activate = { [weak model] in model?.activate(row) }
        }
        divider.isHidden = rows.isEmpty
        if rows != shownRows {
            shownRows = rows
            needsLayout = true
        }
    }

    @objc private func kindChanged() {
        let all = AgentPaneTabKind.allCases
        guard all.indices.contains(kinds.selectedSegment) else { return }
        model.kind = all[kinds.selectedSegment]
        render()
    }

    public func controlTextDidChange(_ notification: Notification) {
        model.text = field.stringValue
        render()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): model.move(1)
        case #selector(NSResponder.moveUp(_:)): model.move(-1)
        case #selector(NSResponder.insertNewline(_:)): model.commit()
        default: return false
        }
        render()
        return true
    }

    // MARK: Layout

    /// The card's height: the field, then the divider and the rows when there are rows.
    private var cardHeight: CGFloat {
        let count = shownRows.count
        guard count > 0 else { return Self.fieldHeight }
        return Self.fieldHeight + 1 + 2 * Metrics.space2 + CGFloat(count) * NativeNewTabRowView.height
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let padding = Metrics.space6
        let spacing = Metrics.space4
        let switchSize = kinds.intrinsicContentSize
        let cardHeight = cardHeight
        // Two flexible gaps share the room left; the one above the switch stops at 120 pt.
        let room = bounds.height - 2 * padding - switchSize.height - cardHeight - 3 * spacing
        let top = padding + min(Self.maxTopGap, max(0, room / 2)) + spacing
        kinds.frame = NSRect(x: floor((bounds.width - switchSize.width) / 2), y: top,
                             width: switchSize.width, height: switchSize.height)
        let width = max(0, min(Self.maxCardWidth, bounds.width - 2 * padding))
        card.frame = NSRect(x: floor((bounds.width - width) / 2), y: kinds.frame.maxY + spacing, width: width, height: cardHeight)
        layoutCard(width: width)
    }

    private func layoutCard(width: CGFloat) {
        // The card is not flipped: lay out from its top edge down.
        let inset = Metrics.space4
        var y = card.bounds.height - Self.fieldHeight
        glass.frame = NSRect(x: inset, y: y + (Self.fieldHeight - 16) / 2, width: 16, height: 16)
        let fieldX = glass.frame.maxX + Metrics.space3
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: fieldX, y: y + floor((Self.fieldHeight - fieldHeight) / 2),
                             width: max(0, width - fieldX - inset), height: fieldHeight)
        guard !shownRows.isEmpty else { return }
        y -= 1
        divider.frame = NSRect(x: 0, y: y, width: width, height: 1)
        y -= Metrics.space2
        for row in rows {
            y -= NativeNewTabRowView.height
            row.frame = NSRect(x: 0, y: y, width: width, height: NativeNewTabRowView.height)
        }
    }

    // MARK: Appearance

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// The card in the theme's colors: the surface, edged by the separator (a theme change re-runs it).
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = Palette.surfaceBackground.cgColor
            card.layer?.borderColor = Palette.separator.cgColor
        }
    }
}
