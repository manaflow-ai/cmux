import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The workspace hover card's history (u3320): one line per moment, newest first, a time column
/// and an icon column, the prompt or what happened beside them. It scrolls past `maxHeight`; the
/// card window ignores the mouse, so the hover card coordinator hands it the wheel
/// (`HoverCardPanel.scrollCard`).
final class WorkspaceHoverCardTimelineView: NSView {
    private static var iconSize: CGFloat { 12 }
    private static var timeColumn: CGFloat { 54 }

    let scrollView = NSScrollView()
    private let header = ChromeLabel(labelWithString: "")
    private let rowsStack = NSStackView()
    private let document = FlippedDocumentView()
    private var heightConstraint: NSLayoutConstraint?
    private var rows: [(time: ChromeLabel, icon: NSImageView, text: ChromeLabel)] = []
    private var entries: [SidebarTimelineEntry] = []
    private var textWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        header.font = Typography.caption
        header.stringValue = Strings.timelineHeader
        header.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = Metrics.space2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        // The document is sized by frame in `configure`, so a wheel right after the card shows
        // scrolls it before any layout pass (a constraint-sized one is zero high until then).
        document.addSubview(rowsStack)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        SystemScrollers.followAsCard(scrollView)
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scrollView)
        let height = scrollView.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        // Just below required: the document is sized by frame from a fitting height measured
        // before it has its width, so a taller real layout (wrapped rows) conflicted with that
        // frame on each layout pass while the card showed (204 conflicts in 3 h, up to 46 a second).
        let documentBottom = rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        documentBottom.priority = .init(999)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.space2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            documentBottom,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The text of each shown line ("2:03 PM Fix the build"), newest first (tests, `debug.hover_cards`).
    var lines: [String] {
        rows.prefix(entries.count).map { [$0.time.stringValue, $0.text.stringValue].joined(separator: " ") }
    }

    /// How far the history is scrolled from its top.
    var scrollOffset: CGFloat { scrollView.contentView.bounds.origin.y }

    /// Shows `entries` at `width`; the list is at most `maxHeight` tall and scrolls past it.
    /// `textLines` is how many lines a prompt may wrap to. A new set of entries scrolls to the top.
    func configure(_ entries: [SidebarTimelineEntry], width: CGFloat, maxHeight: CGFloat, textLines: Int, now: Date) {
        let changed = entries != self.entries
        self.entries = entries
        textWidth = width - Self.timeColumn - Self.iconSize - 2 * Metrics.space2
        while rows.count < entries.count { addRow() }
        for (index, row) in rows.enumerated() {
            let entry = index < entries.count ? entries[index] : nil
            row.time.superview?.isHidden = entry == nil
            guard let entry else { continue }
            row.time.stringValue = WorkspaceHoverCardContent.timelineTime(entry.date, now: now)
            row.icon.image = NSImage.icon(Self.icon(entry.kind), size: Self.iconSize)
            row.text.stringValue = Strings.timelineText(entry)
            row.text.maximumNumberOfLines = entry.kind == .prompt || entry.kind == .waiting ? textLines : 1
            row.text.preferredMaxLayoutWidth = textWidth
        }
        let content = rowsStack.fittingSize.height
        document.frame = CGRect(x: 0, y: 0, width: width, height: content)
        heightConstraint?.constant = min(content, maxHeight)
        if changed { scrollView.contentView.scroll(to: .zero) }
        applyColors()
    }

    static func icon(_ kind: SidebarTimelineEntry.Kind) -> IconName {
        switch kind {
        case .prompt: .composerSend
        case .started: .statusRunning
        case .waiting: .statusNeedsinput
        case .finished: .statusSuccess
        case .failed: .statusError
        }
    }

    private func addRow() {
        let time = ChromeLabel(labelWithString: "")
        time.font = Typography.system(.monospacedDigit, size: Typography.caption.pointSize, weight: .regular)
        time.alignment = .right
        let icon = NSImageView()
        let text = ChromeLabel(wrappingLabelWithString: "")
        text.font = Typography.body
        text.lineBreakMode = .byWordWrapping
        text.truncatesLastVisibleLine = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [time, icon, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Metrics.space2
        NSLayoutConstraint.activate([
            time.widthAnchor.constraint(equalToConstant: Self.timeColumn),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        rows.append((time, icon, text))
    }

    /// Recolors in the card's theme scope (the card runs it inside `performWithTheme`).
    func applyColors() {
        header.textColor = Palette.textSecondary
        for (index, row) in rows.enumerated() {
            let entry = index < entries.count ? entries[index] : nil
            row.time.textColor = Palette.textSecondary
            row.icon.contentTintColor = entry?.kind == .waiting ? Palette.litGlyph : Palette.textSecondary
            // What the person said reads in the primary ink, what happened in the secondary.
            row.text.textColor = entry?.kind == .prompt ? Palette.textPrimary : Palette.textSecondary
        }
    }
}

/// A document view whose origin is its top, so the newest line sits at the top of the list.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
