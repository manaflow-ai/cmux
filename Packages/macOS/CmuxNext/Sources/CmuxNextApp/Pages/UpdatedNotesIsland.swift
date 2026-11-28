import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextUpdater

/// The Updated card's hover popover, native (Lawrence 2026-12: no web view in a popover): the version
/// line, What's New, the top changes (a click opens What's New at that change), "+N more" and Other
/// builds. It paints no glass: it sits in the app's one hover card window (``SidebarUpdatedNotesPopover``),
/// whose glass is the floating panels' own.
@MainActor
final class UpdatedNotesIsland: SidebarSurfaceIsland {
    private weak var services: AppServices?
    private let notes = UpdatedNotesView()
    var view: NSView { notes }
    var onHeightChange: (() -> Void)?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    private var task: Task<Void, Never>?

    var contentWidth: CGFloat { 340 }
    var contentHeight: CGFloat { notes.text == nil ? 0 : notes.fittingHeight(width: contentWidth) }
    var contentSettled: Bool { true }
    var paintsOwnGlass: Bool { false }

    init(services: AppServices?) {
        self.services = services
        notes.onOpen = { [weak self] change in
            let focus = change.flatMap { ChangelogFocus(area: $0.group, entry: $0.title) }
            _ = self?.services?.updater.openWhatsNewForLastUpdate(focus: focus)
            self?.onAction?()
        }
        notes.onOtherBuilds = { [weak self] in
            guard let services = self?.services else { return }
            _ = HomeChannelsPageTab.open(services)
            self?.onAction?()
        }
        // task-owner: the island's; cancelled in close().
        task = Task { @MainActor [weak self] in
            for await highlights in ObservationStream({ [weak self] in self?.services?.updater.surfaceHighlights(updated: true) }) {
                guard let self else { return }
                notes.text = highlights.map { UpdatedCardText($0, background: services?.environment.relaunchBehind != nil) }
                onHeightChange?()
            }
        }
    }

    func close() { task?.cancel() }
}

/// The popover's rows, top down. Flipped.
@MainActor
final class UpdatedNotesView: NSView {
    var onOpen: ((UpdatedCardText.Change?) -> Void)?
    var onOtherBuilds: (() -> Void)?
    var text: UpdatedCardText? {
        didSet { if text != oldValue { rebuild() } }
    }

    private let version = ThemedLabel(font: Typography.cardCaption)
    private let whatsNew = UpdatedCardLink()
    private var rows: [UpdatedNotesRow] = []
    private let more = ThemedLabel(font: Typography.cardCaption)
    private let otherBuilds = UpdatedCardLink()

    override init(frame: NSRect) {
        super.init(frame: frame)
        version.ink = .tertiary
        more.ink = .tertiary
        whatsNew.onPress = { [weak self] in self?.onOpen?(nil) }
        otherBuilds.onPress = { [weak self] in self?.onOtherBuilds?() }
        [version, whatsNew, more, otherBuilds].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        guard let text else { return }
        version.stringValue = text.versionLine
        whatsNew.text = text.whatsNew
        otherBuilds.text = text.otherBuilds
        rows = text.changes.prefix(UpdateHighlights.shownItems).map { change in
            let row = UpdatedNotesRow(change)
            row.onPress = { [weak self] in self?.onOpen?(change) }
            addSubview(row)
            return row
        }
        more.stringValue = text.more(past: UpdateHighlights.shownItems) ?? ""
        more.isHidden = more.stringValue.isEmpty
        needsLayout = true
    }

    private static var pad: CGFloat { Metrics.space3 }

    private func header() -> CGFloat { max(ceil(Typography.cardCaption.boundingRectForFont.height), UpdatedCardLink.height) }

    func fittingHeight(width: CGFloat) -> CGFloat {
        let inner = width - 2 * Self.pad + 2 * Metrics.space1
        var h = Self.pad + header() + Metrics.space1
        for row in rows { h += row.height(width: inner) }
        if !more.isHidden { h += ceil(more.naturalSize.height) + Metrics.space1 }
        return ceil(h + UpdatedCardLink.height + Self.pad)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, pad = Self.pad
        let head = header()
        let linkWidth = whatsNew.fittingWidth
        whatsNew.frame = NSRect(x: w - pad + Metrics.space1 - linkWidth, y: pad + (head - UpdatedCardLink.height) / 2,
                                width: linkWidth, height: UpdatedCardLink.height)
        let vh = ceil(version.naturalSize.height)
        version.frame = NSRect(x: pad, y: pad + (head - vh) / 2, width: max(0, whatsNew.frame.minX - pad - Metrics.space1), height: vh)
        var y = pad + head + Metrics.space1
        let rowX = pad - Metrics.space1, rowW = w - 2 * rowX
        for row in rows {
            let h = row.height(width: rowW)
            row.frame = NSRect(x: rowX, y: y, width: rowW, height: h)
            y += h
        }
        if !more.isHidden {
            let mh = ceil(more.naturalSize.height)
            more.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: mh)
            y += mh + Metrics.space1
        }
        otherBuilds.frame = NSRect(x: rowX, y: y, width: otherBuilds.fittingWidth, height: UpdatedCardLink.height)
    }
}

/// One change: "Fixed:" and its title, its summary under it; the hover fill on the whole row, and a press
/// changes only that fill.
@MainActor
final class UpdatedNotesRow: ClickableButton {
    private lazy var hover = ChromeHover(self, behindContent: true)
    private let label = ThemedLabel(wrappingLabelWithString: "")
    private let summary = ThemedLabel(wrappingLabelWithString: "")
    var onPress: (() -> Void)?

    init(_ change: UpdatedCardText.Change) {
        super.init(frame: .zero)
        isBordered = false
        self.title = ""
        wantsLayer = true
        focusRingType = .none
        target = self
        action = #selector(pressed)
        let line = NSMutableAttributedString(string: change.area + " ", attributes: [.font: NSFontManager.shared.convert(Typography.cardBody, toHaveTrait: .boldFontMask)])
        line.append(NSAttributedString(string: change.title, attributes: [.font: Typography.cardBody]))
        label.attributedStringValue = line
        label.ink = .primary
        label.maximumNumberOfLines = 2
        summary.font = Typography.cardCaption
        summary.stringValue = change.summary ?? ""
        summary.ink = .secondary
        summary.maximumNumberOfLines = 2
        summary.isHidden = change.summary?.isEmpty ?? true
        [label, summary].forEach(addSubview)
        setAccessibilityLabel("\(change.area) \(change.title)")
        hover.followPointer(onChange: { [weak self] in self?.hover.refresh() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    @objc private func pressed() { onPress?() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    private static var inset: CGFloat { Metrics.space1 }

    func height(width: CGFloat) -> CGFloat {
        let inner = max(0, width - 2 * Self.inset)
        var h = ceil(label.size(forWidth: inner).height)
        if !summary.isHidden { h += 2 + ceil(summary.size(forWidth: inner).height) }
        return h + 2 * Self.inset
    }

    override func layout() {
        super.layout()
        let inner = max(0, bounds.width - 2 * Self.inset)
        let th = ceil(label.size(forWidth: inner).height)
        label.frame = NSRect(x: Self.inset, y: Self.inset, width: inner, height: th)
        summary.frame = NSRect(x: Self.inset, y: Self.inset + th + 2, width: inner, height: ceil(summary.size(forWidth: inner).height))
        hover.cornerRadius = Metrics.buttonCornerRadius
    }

    override func mouseDown(with event: NSEvent) {
        hover.state.pressed = true
        super.mouseDown(with: event)
        hover.state.pressed = false
    }
}
