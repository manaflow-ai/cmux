import AppKit
import CmuxAgentQuestion
import CmuxHomeRender

/// A Chief question in a local conversation, as a card: each item's prompt and options, picked with
/// a click (one per single-select item, any number per multi-select item), and Send. Picking only
/// changes this card; Send is the native click that signs the person's decision over the exact
/// answers (HomeProjection+Question). Tool approvals keep their own card (HomeApprovalRowProvider).
/// Items with no options (free text only) cannot be answered here: Send stays off.
final class HomeQuestionRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.homeQuestion"
    struct Local: Codable, Equatable {
        /// Item id -> picked option ids.
        var picked: [String: [String]] = [:]
        var busy = false
        var note: String?
        var ended = false
    }
    struct Payload: Codable, Equatable {
        var question: AgentQuestion
        var local: Local
        var open: Bool { question.isPending && !local.ended }
        var takesClicks: Bool { open && !local.busy }
        /// Every item has a pick, so Send can go.
        var complete: Bool { question.items.allSatisfy { !(local.picked[$0.id] ?? []).isEmpty } }
    }
    enum Target: Equatable {
        case option(item: String, option: String)
        case send
    }

    @MainActor static func install() {
        if CustomRows.provider(kind) == nil { CustomRows.register(HomeQuestionRowProvider()) }
    }

    /// A question this card answers: not a tool approval, from a harness acpmux takes answers for.
    static func answerable(_ question: AgentQuestion) -> Bool {
        HomeApprovalRowProvider.digest(question) == nil && question.source.harness != .acp && !question.items.isEmpty
    }
    static func part(_ question: AgentQuestion, local: Local = .init()) -> Part? {
        guard answerable(question), let custom = custom(Payload(question: question, local: local)) else { return nil }
        return .custom(custom)
    }
    static func custom(_ payload: Payload) -> CustomPart? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return CustomPart(kind: kind, version: HomeDiagramRowProvider.version(String(decoding: data, as: UTF8.self)), payload: data)
    }
    static func payload(_ part: CustomPart) -> Payload? { part.kind == kind ? part.decode(Payload.self) : nil }

    /// The answer the picks make, in the item's option order.
    static func answer(_ p: Payload) -> AgentQuestionAnswer {
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for item in p.question.items {
            let picked = p.local.picked[item.id] ?? []
            selections[item.id] = .init(optionIDs: item.options.map(\.id).filter(picked.contains))
        }
        return AgentQuestionAnswer(selections: selections)
    }

    /// `local` after a click on `option` of `item`: a single-select item holds one pick.
    static func toggled(_ local: Local, item: AgentQuestion.Item, option: String) -> Local {
        var local = local
        var picked = local.picked[item.id] ?? []
        if picked.contains(option) { picked.removeAll { $0 == option } }
        else if item.multiSelect { picked.append(option) }
        else { picked = [option] }
        local.picked[item.id] = picked
        local.note = nil
        return local
    }

    static func status(_ p: Payload) -> String? {
        switch p.question.state {
        case .pending: p.local.note
        case .cancelled: CmuxStrings.questionExpired
        case .answered(let answer): ([CmuxStrings.questionAnswered] + p.question.summaryLines(answer)).joined(separator: "\n")
        }
    }

    static func text(_ p: Payload) -> String {
        var lines: [String] = []
        for item in p.question.items {
            lines.append(item.header.map { "\($0): \(item.prompt)" } ?? item.prompt)
            if !p.open { continue }
            for option in item.options {
                let on = (p.local.picked[item.id] ?? []).contains(option.id)
                lines.append("\(on ? "●" : "○") \(option.label)")
            }
        }
        if let status = status(p) { lines.append(status) }
        return HomeApprovalRowProvider.visible(lines.joined(separator: "\n"))
    }

    struct Layout {
        struct Row {
            let item: String
            let option: String?
            /// The prompt's wrapped text (an item row), or nil (an option row).
            let title: TextLayout?
            /// The option's label, one line.
            let label: String
            let frame: CGRect
        }
        let rows: [Row]
        let status: TextLayout?
        let statusY: CGFloat
        let send: CGRect
        let size: CGSize
    }

    static let optionHeight: CGFloat = 26
    static let gap: CGFloat = 6

    static func layout(_ p: Payload, width: CGFloat) -> Layout {
        let width = max(120, min(420, width))
        let pad = Fixture.bubblePadX
        let inner = max(1, width - 2 * pad)
        var y = Fixture.bubblePadY
        var rows: [Layout.Row] = []
        for item in p.question.items {
            let title = HomeApprovalRowProvider.visible(item.header.map { "\($0): \(item.prompt)" } ?? item.prompt)
            let prompt = TextLayout.make(title, runs: [], maxWidth: inner)
            let height = prompt.textHeight(hard: Fixture.lineHeight)
            rows.append(.init(item: item.id, option: nil, title: prompt, label: title,
                              frame: CGRect(x: pad, y: y, width: inner, height: height)))
            y += height + gap
            guard p.open else { continue }
            for option in item.options {
                rows.append(.init(item: item.id, option: option.id, title: nil, label: HomeApprovalRowProvider.visible(option.label),
                                  frame: CGRect(x: pad, y: y, width: inner, height: optionHeight)))
                y += optionHeight + gap
            }
        }
        var statusLayout: TextLayout?
        let statusY = y
        if let text = Self.status(p) {
            let layout = TextLayout.make(HomeApprovalRowProvider.visible(text), runs: [], maxWidth: inner)
            statusLayout = layout
            y += layout.textHeight(hard: Fixture.lineHeight) + gap
        }
        var send = CGRect(x: pad, y: y, width: inner, height: 0)
        if p.open {
            send.size.height = optionHeight
            y += optionHeight + gap
        }
        return Layout(rows: rows, status: statusLayout, statusY: statusY, send: send,
                      size: CGSize(width: width, height: y - gap + Fixture.bubblePadY))
    }

    static func target(at point: CGPoint, _ p: Payload, width: CGFloat) -> Target? {
        guard p.takesClicks else { return nil }
        let layout = layout(p, width: width)
        if layout.send.height > 0, layout.send.contains(point) { return p.complete ? .send : nil }
        for row in layout.rows where row.frame.contains(point) {
            if let option = row.option { return .option(item: row.item, option: option) }
        }
        return nil
    }

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .bubbleIncoming }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func plainText(_ part: CustomPart) -> String? { Self.payload(part).map(Self.text) }
    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        Self.payload(part).map { Self.layout($0, width: maxWidth).size } ?? .zero
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let p = Self.payload(part) else { return }
        let layout = Self.layout(p, width: rect.width)
        let ink = Fixture.incomingText
        let font = Fixture.bodyFont
        for row in layout.rows {
            let frame = row.frame.offsetBy(dx: rect.minX, dy: rect.minY)
            guard let option = row.option else {
                guard let title = row.title else { continue }
                PartRenderer.drawText(ctx, title, in: CGRect(x: rect.minX, y: frame.minY - Fixture.bubblePadY,
                                                                 width: rect.width, height: frame.height),
                                      outgoing: false)
                continue
            }
            let on = (p.local.picked[row.item] ?? []).contains(option)
            ctx.setFillColor(ink.withAlphaComponent(on ? 0.85 : (p.takesClicks ? 0.1 : 0.05)).cgColor)
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
            TextDraw.line(row.label, font: font, color: on ? Fixture.incoming : ink, x: frame.minX + 12,
                          baseline: frame.midY + (font.ascender + font.descender) / 2, in: ctx)
        }
        if let status = layout.status {
            PartRenderer.drawText(ctx, status, in: CGRect(x: rect.minX, y: rect.minY + layout.statusY - Fixture.bubblePadY,
                                                          width: rect.width, height: status.textHeight(hard: Fixture.lineHeight)),
                                  outgoing: false)
        }
        if layout.send.height > 0 {
            let r = layout.send.offsetBy(dx: rect.minX, dy: rect.minY)
            let ready = p.takesClicks && p.complete
            ctx.setFillColor(ink.withAlphaComponent(ready ? 1 : 0.2).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
            let title = CmuxStrings.questionSend
            TextDraw.line(title, font: font, color: Fixture.incoming, x: r.midX - TextDraw.width(title, font: font) / 2,
                          baseline: r.midY + (font.ascender + font.descender) / 2, in: ctx)
        }
    }
}
