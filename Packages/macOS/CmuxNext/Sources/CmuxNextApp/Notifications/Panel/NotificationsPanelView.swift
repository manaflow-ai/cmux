import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextCompat
import CmuxVisibleRows

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

/// A quiet floating surface with a header, rows newest first, or an empty
/// state. The surface is the shared overlay glass (`Glass.makeOverlayPanel`),
/// never a solid fill (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO
/// JUST USE GLASS."), without another inset card or border around the content.
final class NotificationsPanelView: NSView {
    static let width: CGFloat = 380
    static let maxListHeight: CGFloat = 440
    /// The rows' width: the surface less its inset on each side.
    static var listWidth: CGFloat { width - 2 * Metrics.panelInset }

    var onMarkAllRead: (() -> Void)?
    var onClearAll: (() -> Void)?

    private let background = NSView()
    /// The glass under the content; the panel's clear window is all it covers.
    private let glass = Glass.makeOverlayPanel(cornerRadius: Metrics.panelCornerRadius, interactive: false, tone: .neutralGlass(.transient))
    private let body = NSView()
    private let markAllRead = NSButton()
    private let clearAll = NSButton()
    private let scroll = OverlayScrollView()
    private let list = NSStackView()
    private let empty = NSStackView()
    private let emptyIcon = NSImageView()
    private var listHeight: NSLayoutConstraint?
    private var tinted: [(ChromeLabel, NotificationRowView.Tone)] = []
    private(set) var rowViews: [NotificationRowView] = []
    let listWork = ListWorkMeter() // rows configured, measured and walked (the visible-rows contract)

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.wantsLayer = true
        background.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(body)
        glass.samplesBehindWindow = true
        addSubview(glass)
        addSubview(background)
        // The glass and the background fill the view, and the body fills the background.
        let fills: [(NSView, NSView)] = [(glass, self), (background, self), (body, background)]
        NSLayoutConstraint.activate(fills.flatMap { view, host in
            [view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
             view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor)]
        })
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func build() {
        let titleFont = NSFont.systemFont(ofSize: Typography.body.pointSize + 2, weight: .semibold)
        let title = NotificationRowView.label(NotificationsPanelStrings.title, font: titleFont)
        for (button, text, action, id) in [(markAllRead, NotificationsPanelStrings.markAllRead, #selector(markAllPressed), "markAllRead"),
                                           (clearAll, NotificationsPanelStrings.clearAll, #selector(clearAllPressed), "clearAll")] {
            button.title = text
            button.isBordered = false
            button.font = Typography.body
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
        // Thin, shown only while scrolling (SCROLLBARS-THIN).
        SystemScrollers.follow(scroll)
        document.translatesAutoresizingMaskIntoConstraints = false

        emptyIcon.image = NSImage.icon(.notification, size: 28)
        emptyIcon.image?.accessibilityDescription = NotificationsPanelStrings.title
        emptyIcon.imageScaling = .scaleProportionallyDown
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        emptyIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let emptyTitle = NotificationRowView.label(NotificationsPanelStrings.emptyTitle, font: Typography.bodyEmphasized)
        let emptyDetail = NotificationRowView.label(NotificationsPanelStrings.emptySubtitle, font: Typography.caption)
        tinted = [(title, .primary), (emptyTitle, .secondary), (emptyDetail, .tertiary)]
        empty.setViews([emptyIcon, emptyTitle, emptyDetail], in: .center)
        empty.orientation = .vertical
        empty.spacing = Metrics.space2
        empty.edgeInsets = NSEdgeInsets(top: Metrics.space6 + Metrics.space2, left: Metrics.space3,
                                        bottom: Metrics.space6 + Metrics.space2, right: Metrics.space3)

        for view in [header, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        let inset = Metrics.panelInset
        let listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        self.listHeight = listHeight
        NSLayoutConstraint.activate([
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
        listWork.rebuilt(rows.count) // every view is new (`NotificationsPanelController.render`); fittingSize measures each
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
        listWork.walked(rowViews.count)
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
            glass.cornerRadius = Metrics.panelCornerRadius
            for (label, tone) in tinted { label.textColor = tone.color }
            emptyIcon.contentTintColor = Palette.textSecondary
            for button in [markAllRead, clearAll] { button.contentTintColor = Palette.textSecondary }
        }
    }

    @objc private func markAllPressed() { onMarkAllRead?() }
    @objc private func clearAllPressed() { onClearAll?() }
}

extension NotificationsPanelView: VisibleRowsList { var rowViewsAlive: Int { rowViews.count } }

private final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}
