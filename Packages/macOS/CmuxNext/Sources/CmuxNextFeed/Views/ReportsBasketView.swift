import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Labs dogfood for the no-wake reports target. Durable mailbox rows are
/// projected here as a human-only basket; selecting Reply sends a new
/// addressed message through the host callback and never mutates the report.
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md rule 1). It follows `model.reports` with a
/// `FrameObservation` while the view is in a window (one render at the next frame after a change);
/// leaving the window cancels it, and coming back reads the model again.
final class ReportsBasketView: NSView {
    let model: FeedModel
    let onReply: (@MainActor (ReportReply) async -> Bool)?
    private(set) var selected: String?
    private(set) var draft = ""
    /// Reports whose reply is being sent: their Reply button waits for the answer, so a second
    /// press or key repeat cannot send the same reply twice.
    private(set) var sending: Set<String> = []
    /// The report whose last reply was not sent (its draft stays).
    private(set) var notSent: String?
    /// Each report's last reply that was not sent: the same reply sent again keeps its id, so a
    /// send that passed its deadline after acpmux queued it is not delivered twice.
    private var unsent: [String: ReportReply] = [:]

    private var colors: ReportsBasketColors?
    /// The app's one main-thread scheduler, and the reports followed while in a window.
    private let mainWork: MainWorkScheduler
    private var reportsWatch: FrameObservation<[FeedReport]>?

    private(set) var rows: [ReportsBasketRow] = []
    private(set) var detail: ReportsBasketDetail?
    private let title = ReportsBasketText.label(FeedStrings.reportsTitle, size: TypeScale.title, weight: TypeScale.emphasis)
    private let subtitle = ReportsBasketText.label(FeedStrings.reportsSubtitle, size: TypeScale.caption)
    private let labs = ReportsBasketText.label(FeedStrings.reportsLabs, size: TypeScale.caption,
                                               weight: TypeScale.emphasis, rounded: true)
    private let lines = [ReportsBasketHairline(), ReportsBasketHairline(vertical: true)]
    private let list = ReportsBasketText.stack([], spacing: 2, insets: 8)
    private lazy var listScroll = ReportsBasketText.scroll(list)
    private let emptyIcon = ReportsBasketText.symbol("tray", size: TypeScale.body)
    private let emptyTitle = ReportsBasketText.label(FeedStrings.reportsEmpty, size: TypeScale.body)
    private let emptyHint = ReportsBasketText.label(FeedStrings.reportsEmptyHint, size: TypeScale.caption, lines: 0)
    private lazy var empty = ReportsBasketText.centered([emptyIcon, emptyTitle, emptyHint], padding: 28)
    private let pickIcon = ReportsBasketText.symbol("arrow.left", size: TypeScale.body)
    private let pickTitle = ReportsBasketText.label(FeedStrings.reportsSelect, size: TypeScale.body)
    private lazy var pick = ReportsBasketText.centered([pickIcon, pickTitle], padding: 0)
    private let content = NSView()
    private let side = NSView()

    private var reports: [FeedReport] { model.reports }

    init(model: FeedModel, mainWork: MainWorkScheduler, onReply: (@MainActor (ReportReply) async -> Bool)?) {
        self.model = model
        self.mainWork = mainWork
        self.onReply = onReply
        super.init(frame: .zero)
        wantsLayer = true
        build()
        render()
        apply(ReportsBasketColors())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        emptyHint.alignment = .center
        labs.setContentCompressionResistancePriority(.required, for: .horizontal)
        labs.setContentHuggingPriority(.required, for: .horizontal)
        let titles = ReportsBasketText.stack([title, subtitle], spacing: 2)
        let header = ReportsBasketText.stack([titles, labs], vertical: false, alignment: .centerY)
        header.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        side.translatesAutoresizingMaskIntoConstraints = false
        let column = ReportsBasketText.stack([header, lines[0], content])
        for part in [header, lines[0], content] { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        ReportsBasketText.flexible(content, .vertical)
        ReportsBasketText.flexible(side, .horizontal)
        ReportsBasketText.flexible(titles, .horizontal)
        let split = ReportsBasketText.stack([column, lines[1], side], vertical: false, alignment: .top)
        embed(split)
        for part in [column, lines[1], side] { part.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true }
        let ideal = column.widthAnchor.constraint(equalToConstant: 380)
        ideal.priority = .defaultLow
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            ideal,
        ])
    }

    /// Shows `child` alone in `container`.
    private func show(_ child: NSView, in container: NSView) {
        guard child.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        container.embed(child)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            reportsWatch?.cancel()
            reportsWatch = nil
            return
        }
        selected = selected ?? reports.first?.id
        if reportsWatch == nil {
            // node-free: the panel, the page tab and the sidebar section each follow only while the basket is in a window
            reportsWatch = FrameObservation(owner: "feed.reportsBasket", delivery: .visible(nil), on: mainWork) { [model] in
                model.reports
            } onChange: { [weak self] _ in
                self?.render()
            }
        }
        render()
    }

    /// Draws the list and the selected report from the model and this view's state.
    private func render() {
        let reports = reports
        if rows.map(\.item.id) == reports.map(\.id) {
            for (row, report) in zip(rows, reports) where row.item != report { row.update(report) }
        } else {
            rows.forEach { $0.removeFromSuperview() }
            rows = reports.map { report in ReportsBasketRow(item: report) { [weak self] in self?.select(report.id) } }
            for row in rows {
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
                if let colors { row.apply(colors) }
            }
        }
        for row in rows { row.selected = row.item.id == selected }
        show(reports.isEmpty ? empty : listScroll, in: content)

        guard let report = reports.first(where: { $0.id == selected }) else {
            detail = nil
            show(pick, in: side)
            return
        }
        let shown: ReportsBasketDetail
        if let detail, detail.item.id == report.id {
            if detail.item != report { detail.update(report) }
            shown = detail
        } else {
            shown = ReportsBasketDetail(item: report, draft: draft,
                                        onDraft: { [weak self] in self?.draft = $0 },
                                        onSend: { [weak self] in self?.send() })
            if let colors { shown.apply(colors) }
            detail = shown
        }
        shown.setState(sending: sending.contains(report.id), notSent: notSent == report.id)
        show(shown, in: side)
    }

    /// Selects a report and starts its reply empty.
    func select(_ id: String) {
        selected = id
        setDraft("")
        render()
    }

    private func setDraft(_ text: String) {
        draft = text
        detail?.setDraft(text)
    }

    /// Sends the draft to the selected report's sender.
    func send() {
        guard let report = reports.first(where: { $0.id == selected }) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = report.id
        guard !text.isEmpty, let onReply, !sending.contains(id) else { return }
        let reply = ReportReply(session: report.sender, text: text, retrying: unsent[id])
        sending.insert(id)
        notSent = nil
        render()
        // The host sends off the main thread and answers once acpmux took the reply (or
        // refused, or passed its deadline). A sent reply clears the draft unless the
        // person typed on or chose another report; a refused one keeps it.
        // task-owner: one reply send; it ends when the host answers (bounded by its deadline)
        // main-hop-allow: onReply is the host's main-actor async send seam (acpmux takes the reply off main); the answer re-renders this view's sending state
        Task { @MainActor [weak self] in
            let sent = await onReply(reply)
            guard let self else { return }
            self.sending.remove(id)
            if !sent {
                self.notSent = id
                self.unsent[id] = reply
            } else {
                self.unsent[id] = nil
                if self.selected == id, self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.setDraft("") }
            }
            self.render()
        }
    }

    func apply(_ colors: ReportsBasketColors) {
        guard colors != self.colors else { return }
        self.colors = colors
        layer?.backgroundColor = colors.background.cgColor
        title.textColor = colors.primary
        subtitle.textColor = colors.tertiary
        labs.textColor = colors.tertiary
        emptyIcon.contentTintColor = colors.secondary
        emptyTitle.textColor = colors.secondary
        emptyHint.textColor = colors.tertiary
        pickIcon.contentTintColor = colors.tertiary
        pickTitle.textColor = colors.tertiary
        lines.forEach { $0.apply(colors) }
        rows.forEach { $0.apply(colors) }
        detail?.apply(colors)
    }
}
