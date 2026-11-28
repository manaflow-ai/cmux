public import AppKit
import CmuxNextDesign
public import CmuxNextSidebar

/// The sidebar's Apps section (RFD 0003 E-C, behind `experiments.appsTier`): the person's and team's
/// apps in the order Rust gave (pinned first), each with a status dot (live green, off gray), its
/// title and its version line, then a `+ Publish preview…` row. A refused list draws one muted note,
/// never an empty list. Rows are values the caller laid out; clicks go back through closures.
public final class AppsTierSectionView: NSView {
    /// One app row as drawn.
    public struct Row: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var live: Bool

        public init(title: String, detail: String, live: Bool) {
            self.title = title
            self.detail = detail
            self.live = live
        }
    }

    /// What the section draws: nil `rows` before the first answer.
    public struct Model: Equatable, Sendable {
        public var rows: [Row]?
        public var publishRow: Bool
        public var error: String?

        public init(rows: [Row]?, publishRow: Bool, error: String?) {
            self.rows = rows
            self.publishRow = publishRow
            self.error = error
        }
    }

    static let rowHeight: CGFloat = 26
    private var model = Model(rows: nil, publishRow: true, error: nil)
    private var rowViews: [AppsTierRowView] = []
    private let note = NSTextField(wrappingLabelWithString: "")
    private var hint: String?
    private let openRow: (Int) -> Void
    private let publish: () -> Bool
    /// The sidebar re-asks the height (`SidebarAppSectionProvider.onContentChange`).
    public var onHeightChange: (() -> Void)?

    /// `openRow`: an app row's click (its index); `publish`: the publish row's click, false when
    /// nothing could publish here (the section then says how to get a preview).
    public init(openRow: @escaping (Int) -> Void, publish: @escaping () -> Bool) {
        self.openRow = openRow
        self.publish = publish
        super.init(frame: .zero)
        note.font = Typography.caption
        note.isSelectable = false
        note.maximumNumberOfLines = 2
        note.cell?.truncatesLastVisibleLine = true
        addSubview(note)
        show(model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override public var isFlipped: Bool { true }

    /// The note's line: the list's refusal, the publish row's hint, or the first read.
    private var noteText: String? {
        if let error = model.error { return Self.failed(error) }
        if let hint { return hint }
        return model.rows == nil ? Self.loading : nil
    }

    public var preferredHeight: CGFloat {
        CGFloat(rowViews.count) * Self.rowHeight + (noteText == nil ? 0 : Self.rowHeight)
    }

    /// Draws `model` (its rows, then the publish row).
    public func show(_ model: Model) {
        self.model = model
        var shown: [AppsTierRowView.Content] = (model.rows ?? []).enumerated().map { .app($0.offset, $0.element) }
        if model.publishRow { shown.append(.publish) }
        while rowViews.count > shown.count { rowViews.popLast()?.removeFromSuperview() }
        while rowViews.count < shown.count {
            let row = AppsTierRowView { [weak self] content in self?.clicked(content) }
            addSubview(row)
            rowViews.append(row)
        }
        for (row, content) in zip(rowViews, shown) { row.content = content }
        note.stringValue = noteText ?? ""
        note.isHidden = noteText == nil
        needsLayout = true
        onHeightChange?()
    }

    private func clicked(_ content: AppsTierRowView.Content) {
        switch content {
        case .app(let index, _): openRow(index)
        case .publish:
            hint = publish() ? nil : Self.publishHint
            show(model)
        }
    }

    override public func layout() {
        super.layout()
        var y: CGFloat = 0
        if noteText != nil {
            note.frame = NSRect(x: 8, y: 4, width: max(0, bounds.width - 16), height: Self.rowHeight - 4)
            y = Self.rowHeight
        }
        for row in rowViews {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
            y += Self.rowHeight
        }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        performWithTheme { note.textColor = Palette.textTertiary }
        for row in rowViews { row.needsDisplay = true }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        performWithTheme { note.textColor = Palette.textTertiary }
    }
}

extension AppsTierSectionView {
    /// The section's contribution, and its place: the bottom band, before the widget area (never
    /// in the layout document).
    public static let contribution = "cmux.appsTier#apps"
    public static var layoutSection: LayoutSection {
        LayoutSection(id: LayoutSectionID("sec_apps_tier"), title: title, region: .bottom, content: .app, contribution: contribution)
    }

    /// The section's header title.
    public static var title: String { AppsStrings.tierTitle }
    static var publishRowTitle: String { AppsStrings.tierPublishRow }
    static var publishHint: String { AppsStrings.tierPublishHint }
    static var loading: String { AppsStrings.tierLoading }
    static func failed(_ reason: String) -> String { AppsStrings.tierFailed(reason) }
}

/// One row of the Apps section: a dot, the title and the version line; or the publish row.
final class AppsTierRowView: NSView {
    enum Content: Equatable {
        case app(Int, AppsTierSectionView.Row)
        case publish
    }

    var content: Content = .publish {
        didSet {
            guard content != oldValue else { return }
            apply()
        }
    }

    private let dot = CALayer()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let click: (Content) -> Void
    private var hover: PointerHover?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(click: @escaping (Content) -> Void) {
        self.click = click
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        dot.cornerRadius = 3.5
        dot.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(dot)
        title.font = Typography.body
        title.lineBreakMode = .byTruncatingTail
        detail.font = Typography.caption
        detail.alignment = .right
        addSubview(title)
        addSubview(detail)
        hover = PointerHover(self) { [weak self] hovering in self?.isHovered = hovering }
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    private func apply() {
        switch content {
        case .app(_, let row):
            title.stringValue = row.title
            detail.stringValue = row.detail
            dot.isHidden = false
            setAccessibilityLabel("\(row.title), \(row.detail)")
        case .publish:
            title.stringValue = AppsTierSectionView.publishRowTitle
            detail.stringValue = ""
            dot.isHidden = true
            setAccessibilityLabel(AppsTierSectionView.publishRowTitle)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = isHovered ? Palette.hoverFill.cgColor : NSColor.clear.cgColor
            if case .app(_, let row) = content {
                dot.backgroundColor = (row.live ? NSColor.systemGreen : Palette.textTertiary).cgColor
                title.textColor = Palette.textPrimary
            } else {
                title.textColor = Palette.textSecondary
            }
            detail.textColor = Palette.textTertiary
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: 12, y: (height - 7) / 2, width: 7, height: 7)
        CATransaction.commit()
        let detailSize = detail.intrinsicContentSize
        let detailWidth: CGFloat = detail.stringValue.isEmpty ? 0 : min(80, detailSize.width)
        let left: CGFloat = dot.isHidden ? 12 : 26
        let titleHeight = title.intrinsicContentSize.height
        detail.frame = NSRect(x: bounds.width - 10 - detailWidth, y: (height - detailSize.height) / 2,
                              width: detailWidth, height: detailSize.height)
        title.frame = NSRect(x: left, y: (height - titleHeight) / 2, width: max(0, detail.frame.minX - 6 - left), height: titleHeight)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        click(content)
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        click(content)
        return true
    }
}
