import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The workspace hover card's history (u3320): one line per moment, newest first, a time column
/// and an icon column, the prompt or what happened beside them. It scrolls past `maxHeight`; the
/// card window ignores the mouse, so the hover card coordinator hands it the wheel
/// (`HoverCardPanel.scrollCard`).
///
/// The lines are laid out by frame, each text measured once at its wrap width: a card slides
/// to every row the pointer crosses while it shows, and the history's lines as stack views
/// under constraints cost about 7 ms of main thread per row crossed (twenty wrapping lines
/// solved by `fittingSize`, then again by the card's fit), so the row's hover trailed the
/// pointer (Lawrence 2026-10-21, "there's lag here fix it"). The view itself keeps its header
/// and the scroll view's height under constraints.
final class WorkspaceHoverCardTimelineView: NSView {
    private static var iconSize: CGFloat { 12 }
    private static var timeColumn: CGFloat { 54 }

    let scrollView = NSScrollView()
    private let header = ChromeLabel(labelWithString: "")
    private let document = FlippedDocumentView()
    private var heightConstraint: NSLayoutConstraint?
    private var rows: [Line] = []
    private var entries: [SidebarTimelineEntry] = []
    /// What the lines were last laid out for: the same entries, width and line limit only
    /// rewrite their times.
    private var laidOut: (entries: [SidebarTimelineEntry], width: CGFloat, textLines: Int)?

    /// One history line's views, placed by frame in the document.
    private struct Line {
        let time: ChromeLabel
        let icon: NSImageView
        let text: ChromeLabel
        var views: [NSView] { [time, icon, text] }
    }

    init() {
        super.init(frame: .zero)
        header.font = Typography.caption
        header.stringValue = Strings.timelineHeader
        header.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        SystemScrollers.followThin(scrollView)
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scrollView)
        let height = scrollView.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.space2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
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
        while rows.count < entries.count { addRow() }
        for (index, row) in rows.enumerated() {
            let entry = index < entries.count ? entries[index] : nil
            row.views.forEach { $0.isHidden = entry == nil }
            guard let entry else { continue }
            row.time.stringValue = WorkspaceHoverCardContent.timelineTime(entry.date, now: now)
        }
        if let laidOut, laidOut.entries == entries, laidOut.width == width, laidOut.textLines == textLines {
            // Only the times can have moved, and a time sits in its fixed column.
            heightConstraint?.constant = min(document.frame.height, maxHeight)
            return applyColors()
        }
        laidOut = (entries, width, textLines)
        let textX = Self.timeColumn + Self.iconSize + 2 * Metrics.space2
        let textWidth = max(0, width - textX)
        var y: CGFloat = 0
        for (index, entry) in entries.enumerated() {
            let row = rows[index]
            row.icon.image = NSImage.icon(Self.icon(entry.kind), size: Self.iconSize)
            row.text.stringValue = Strings.timelineText(entry)
            row.text.maximumNumberOfLines = entry.kind == .prompt || entry.kind == .waiting ? textLines : 1
            row.text.preferredMaxLayoutWidth = textWidth
            let text = row.text.size(forWidth: textWidth)
            let time = row.time.size(forWidth: Self.timeColumn)
            // The time on the text's first baseline; the icon centered on that line's capitals, as
            // every hover card icon (`NSFont.iconBaselineOffsetFromTop`), not standing on the baseline.
            let baseline = row.text.firstBaselineOffsetFromTop
            let timeY = y + max(0, baseline - row.time.firstBaselineOffsetFromTop)
            let iconBaseline = (row.text.font ?? Typography.body).iconBaselineOffsetFromTop(iconHeight: Self.iconSize)
            let iconY = y + max(0, baseline - iconBaseline)
            row.text.frame = CGRect(x: textX, y: y, width: textWidth, height: text.height)
            row.time.frame = CGRect(x: 0, y: timeY, width: Self.timeColumn, height: time.height)
            row.icon.frame = CGRect(x: Self.timeColumn + Metrics.space2, y: iconY, width: Self.iconSize, height: Self.iconSize)
            y = max(y + text.height, timeY + time.height, iconY + Self.iconSize)
            if index < entries.count - 1 { y += Metrics.space2 }
        }
        let content = y.rounded(.up)
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
        let line = Line(time: time, icon: icon, text: text)
        line.views.forEach(document.addSubview)
        rows.append(line)
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
