import AppKit
import CmuxNextDesign

/// The panel's window: a borderless child panel of the shell window (so it
/// stays above Chromium page windows and moves with the window). It takes
/// key status for the keyboard while the app is active and closes when it
/// loses it, like the old app's popover.
final class NotificationsPanel: ActiveAppKeyPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("cmux.notifications")
        setAccessibilityRole(.popover)
    }

    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// Glass card: a header with Mark All Read and Clear All, then the rows
/// newest first, or the empty state.
final class NotificationsPanelView: NSView {
    static let width: CGFloat = 360
    static let maxListHeight: CGFloat = 440
    /// The rows' width: the card less its inset on each side.
    static var listWidth: CGFloat { width - 2 * Metrics.panelInset }

    var onMarkAllRead: (() -> Void)?
    var onClearAll: (() -> Void)?

    private let glass = Glass.makePanel()
    private let body = NSView()
    private let markAllRead = NSButton()
    private let clearAll = NSButton()
    private let scroll = NSScrollView()
    private let list = NSStackView()
    private let empty = NSStackView()
    private var listHeight: NSLayoutConstraint?
    private var tinted: [(NSTextField, NotificationRowView.Tone)] = []
    private(set) var rowViews: [NotificationRowView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.contentView = body
        glass.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            body.topAnchor.constraint(equalTo: glass.topAnchor),
            body.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func build() {
        let title = NotificationRowView.label(NotificationsPanelStrings.title, font: Typography.header)
        for (button, text, action, id) in [(markAllRead, NotificationsPanelStrings.markAllRead, #selector(markAllPressed), "markAllRead"),
                                           (clearAll, NotificationsPanelStrings.clearAll, #selector(clearAllPressed), "clearAll")] {
            button.title = text
            button.isBordered = false
            button.font = Typography.caption
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier("cmux.notifications.\(id)")
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, markAllRead, clearAll])
        header.spacing = Metrics.space3

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        let document = FlippedView()
        document.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Overlay scrollers keep the clip as wide as the rows' fixed width.
        scroll.scrollerStyle = .overlay
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged),
                                               name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        document.translatesAutoresizingMaskIntoConstraints = false

        let emptyTitle = NotificationRowView.label(NotificationsPanelStrings.emptyTitle, font: Typography.bodyEmphasized)
        let emptyDetail = NotificationRowView.label(NotificationsPanelStrings.emptySubtitle, font: Typography.caption)
        tinted = [(title, .primary), (emptyTitle, .secondary), (emptyDetail, .tertiary)]
        empty.setViews([emptyTitle, emptyDetail], in: .center)
        empty.orientation = .vertical
        empty.spacing = Metrics.space1
        empty.edgeInsets = NSEdgeInsets(top: Metrics.space6, left: 0, bottom: Metrics.space6, right: 0)

        for view in [header, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        let inset = Metrics.panelInset
        let listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        self.listHeight = listHeight
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: body.topAnchor, constant: inset),
            header.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset + Metrics.space2),
            header.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset - Metrics.space2),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.space2),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -inset),
            listHeight,
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            // Rows wrap at their real width, so the list measures true.
            list.widthAnchor.constraint(equalToConstant: Self.listWidth),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    /// Replaces the rows; returns the card height it needs. Until the
    /// first ledger reply (`loaded` false) an empty list shows nothing
    /// rather than the empty state.
    func show(_ rows: [NotificationRowView], loaded: Bool) -> CGFloat {
        rowViews = rows
        list.setViews(rows, in: .top)
        for row in rows { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        empty.isHidden = !rows.isEmpty || !loaded
        markAllRead.isEnabled = rows.contains { $0.row.unread }
        clearAll.isEnabled = !rows.isEmpty
        list.layoutSubtreeIfNeeded()
        let content = rows.isEmpty ? (loaded ? empty.fittingSize.height : 0) : list.fittingSize.height
        listHeight?.constant = min(ceil(content), Self.maxListHeight)
        layoutSubtreeIfNeeded()
        return fittingSize.height
    }

    func select(_ index: Int?) {
        for (offset, row) in rowViews.enumerated() { row.isSelected = offset == index }
        if let index, rowViews.indices.contains(index) { rowViews[index].scrollToVisible(rowViews[index].bounds) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            for (label, tone) in tinted { label.textColor = tone.color }
            for button in [markAllRead, clearAll] { button.contentTintColor = Palette.textSecondary }
        }
    }

    @objc private func scrollerStyleChanged(_ note: Notification) { scroll.scrollerStyle = .overlay }

    @objc private func markAllPressed() { onMarkAllRead?() }
    @objc private func clearAllPressed() { onClearAll?() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
