import AppKit
import CoreGraphics
import CoreText
import Foundation
import os

/// cmux: a reply's pipe table as a card at the chat's full width (Leo 2026-10-20), a drawn custom
/// row (CustomRows.swift, `.fullWidth`) like the Mermaid bubbles (``HomeDiagramRowProvider``).
/// `HomeMapping.parts` cuts an agent's text at its tables (``HomeTableSplitter``): an assignment
/// table becomes a plan card (``HomePlanRowProvider``), any other a table card with real column
/// widths. Copy and VoiceOver read the table's Markdown as written. Debug Settings > Home > Rich
/// tables off (``isOn``) maps tables as text again, in the bubble.
final class HomeTableRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.table"

    struct Payload: Codable, Hashable {
        var raw: String
        var table: HomeTable
    }

    // Lock carve-out: the mapping reads it on the loader queue and the main thread; a Bool.
    private static let enabled = OSAllocatedUnfairLock(initialState: true)
    /// Tables draw as cards (the host's Debug Settings value; default on).
    static var isOn: Bool {
        get { enabled.withLock { $0 } }
        set { enabled.withLock { $0 = newValue } }
    }

    /// The registered provider (nil: tables stay text).
    static var installed: HomeTableRowProvider? { CustomRows.provider(kind) as? HomeTableRowProvider }

    /// Registers the table and plan providers once per process.
    static func install() {
        if installed == nil { CustomRows.register(HomeTableRowProvider()) }
        if HomePlanRowProvider.installed == nil { CustomRows.register(HomePlanRowProvider()) }
    }

    /// The card for a table: a plan card for an assignment list, else a table card.
    static func part(_ table: HomeTable, raw: String) -> Part? {
        if HomePlanRowProvider.installed != nil, let card = HomePlanCard(table),
           let custom = try? CustomPart(kind: HomePlanRowProvider.kind, version: HomeDiagramRowProvider.version(raw),
                                        value: HomePlanRowProvider.Payload(raw: raw, card: card)) {
            return .custom(custom)
        }
        guard let custom = try? CustomPart(kind: kind, version: HomeDiagramRowProvider.version(raw), value: Payload(raw: raw, table: table))
        else { return nil }
        return .custom(custom)
    }

    static func payload(_ part: CustomPart) -> Payload? { part.decode(Payload.self) }

    // MARK: TranscriptCustomRowProvider

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .fullWidth }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func plainText(_ part: CustomPart) -> String? { Self.payload(part)?.raw }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let payload = Self.payload(part) else { return CGSize(width: maxWidth, height: 24) }
        let grid = HomeTableGrid(payload.table, available: maxWidth)
        return CGSize(width: maxWidth, height: grid.height)
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let payload = Self.payload(part) else { return }
        HomeTableGrid(payload.table, available: rect.width).draw(ctx, at: rect.origin)
    }

    func tapped(_ part: CustomPart, ref: PartRef) -> Bool {
        guard let payload = Self.payload(part) else { return false }
        let links = payload.table.rows.flatMap { $0 }.flatMap { HomeTableCell(markdown: $0).links }
        let items = links.map { (HomeCardLinks.title($0), $0) }
        guard !items.isEmpty else { return false }
        Task { @MainActor in HomeCardLinks.offer(items) }
        return true
    }
}

/// A table card's measured grid: column widths, row heights and each cell's text, laid out for one
/// width. Pure CoreText, any thread.
struct HomeTableGrid {
    static let pad: CGFloat = 12
    static let cellPadX: CGFloat = 8
    static let cellPadY: CGFloat = 6
    /// A column's natural width stops here (a long cell wraps instead of pushing the others out).
    static let maxNatural: CGFloat = 440

    let widths: [CGFloat]
    let heights: [CGFloat]
    let cells: [[NSAttributedString]]
    let alignments: [HomeTable.Alignment]
    let cardWidth: CGFloat
    var height: CGFloat { heights.reduce(0, +) + 2 * Self.pad }

    init(_ table: HomeTable, available: CGFloat) {
        let header = table.header.map { Self.attributed(HomeTableCell(markdown: $0), header: true) }
        let body = table.rows.map { $0.map { Self.attributed(HomeTableCell(markdown: $0), header: false) } }
        let all = [header] + body
        let natural = (0..<table.columns).map { c in
            min(Self.maxNatural, all.map { Self.lineWidth($0[c]) }.max() ?? 0) + 2 * Self.cellPadX
        }
        let room = max(1, available - 2 * Self.pad)
        let widths = HomeTableColumns.widths(natural: natural.map { $0.rounded(.up) }, available: room)
        self.widths = widths
        heights = all.map { (row: [NSAttributedString]) -> CGFloat in
            var tallest: CGFloat = 0
            for (text, width) in zip(row, widths) {
                tallest = max(tallest, Self.textHeight(text, width: width - 2 * Self.cellPadX))
            }
            return tallest + 2 * Self.cellPadY
        }
        cells = all
        alignments = table.alignments
        cardWidth = min(available, widths.reduce(0, +) + 2 * Self.pad)
    }

    func draw(_ ctx: CGContext, at origin: CGPoint) {
        let card = CGRect(x: origin.x, y: origin.y, width: cardWidth, height: height)
        HomeCardDraw.background(ctx, card)
        // Columns at their 56 pt floor can be wider than a very narrow chat: they stop at the card.
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: card.insetBy(dx: Self.pad / 2, dy: 0))
        var y = card.minY + Self.pad
        for (r, (row, rowHeight)) in zip(cells, heights).enumerated() {
            var x = card.minX + Self.pad
            for (c, (text, width)) in zip(row, widths).enumerated() {
                let frame = CGRect(x: x + Self.cellPadX, y: y + Self.cellPadY, width: width - 2 * Self.cellPadX, height: rowHeight - 2 * Self.cellPadY)
                HomeCardDraw.text(ctx, text, in: frame, alignment: alignments[checked: c] ?? .leading)
                x += width
            }
            y += rowHeight
            if r < cells.count - 1 {
                HomeCardDraw.hairline(ctx, from: CGPoint(x: card.minX + Self.pad, y: y), to: CGPoint(x: card.maxX - Self.pad, y: y), strong: r == 0)
            }
        }
    }

    static func attributed(_ cell: HomeTableCell, header: Bool) -> NSAttributedString {
        let font = header ? HomeFonts.system(ofSize: 12, weight: .semibold) : Fixture.bodyFont
        let color = header ? Fixture.secondaryText : Fixture.incomingText
        let s = NSMutableAttributedString(string: cell.text, attributes: [.font: font, .foregroundColor: color])
        if !header {
            let bold = HomeFonts.system(ofSize: Fixture.bodyFont.pointSize, weight: .semibold)
            for range in cell.bold where NSMaxRange(range) <= s.length { s.addAttribute(.font, value: bold, range: range) }
        }
        return s
    }

    static func lineWidth(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)).rounded(.up)
    }

    /// The height ``HomeCardDraw/text`` draws `text` in at `width`: the same lines, each rounded up.
    static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return Fixture.bodyFont.pointSize + 4 }
        return HomeCardDraw.lines(text, width: width).reduce(0) { $0 + $1.height }
    }
}

/// The Chief's plan card: an assignment table as one row per step, its owner chip, what it builds,
/// a state pill (from the live ``ChiefPlan``, else the table's own words) and its pull requests.
final class HomePlanRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.plan"

    struct Payload: Codable, Hashable {
        var raw: String
        var card: HomePlanCard
    }

    // Lock carve-out: the host publishes the plan on main; the row bitmaps read it off main.
    private static let live = OSAllocatedUnfairLock(initialState: ChiefPlan.empty)
    /// The Chief's live plan (the host copies its ``ChiefPlanBoard`` here): rows drawn after a change
    /// show the new states.
    static var plan: ChiefPlan {
        get { live.withLock { $0 } }
        set { live.withLock { $0 = newValue } }
    }

    static var installed: HomePlanRowProvider? { CustomRows.provider(kind) as? HomePlanRowProvider }
    static func payload(_ part: CustomPart) -> Payload? { part.decode(Payload.self) }

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .fullWidth }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func plainText(_ part: CustomPart) -> String? { Self.payload(part)?.raw }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let payload = Self.payload(part) else { return CGSize(width: maxWidth, height: 24) }
        return CGSize(width: maxWidth, height: HomePlanLayout(payload.card, states: payload.card.rows.map(\.written), width: maxWidth).height)
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let payload = Self.payload(part) else { return }
        // Measured with the written states; the pill's width never changes a row's height.
        HomePlanLayout(payload.card, states: payload.card.states(in: Self.plan), width: rect.width).draw(ctx, at: rect.origin)
    }

    func tapped(_ part: CustomPart, ref: PartRef) -> Bool {
        guard let payload = Self.payload(part) else { return false }
        let plan = Self.plan
        var items: [(String, URL)] = []
        for row in payload.card.rows {
            if let owner = row.owner, let link = plan.step(owner: owner)?.ownerLink { items.append((CmuxStrings.planOpenOwner(owner), link)) }
            for pr in row.pullRequests {
                if let url = URL(string: pr) { items.append((HomeCardLinks.title(url), url)) }
            }
        }
        guard !items.isEmpty else { return false }
        Task { @MainActor in HomeCardLinks.offer(items) }
        return true
    }
}

/// A plan card laid out for one width. Pure CoreText, any thread.
struct HomePlanLayout {
    static let pad: CGFloat = 12
    static let rowPadY: CGFloat = 8
    static let chipWidth: CGFloat = 54
    static let pillWidth: CGFloat = 104
    static let lineGap: CGFloat = 2

    struct Line {
        var owner: String?
        var title: NSAttributedString
        var detail: NSAttributedString?
        var titleHeight: CGFloat
        var detailHeight: CGFloat
        var state: ChiefPlanStep.State?
    }

    let header: NSAttributedString
    let lines: [Line]
    let width: CGFloat
    let textWidth: CGFloat
    var headerHeight: CGFloat { 18 }
    var height: CGFloat {
        2 * Self.pad + headerHeight + lines.reduce(0) { $0 + Self.rowHeight($1) }
    }

    static func rowHeight(_ line: Line) -> CGFloat {
        2 * rowPadY + max(18, line.titleHeight) + (line.detail == nil ? 0 : lineGap + line.detailHeight)
    }

    init(_ card: HomePlanCard, states: [ChiefPlanStep.State?], width: CGFloat) {
        self.width = width
        let textWidth = max(60, width - 2 * Self.pad - Self.chipWidth - Self.pillWidth - 16)
        self.textWidth = textWidth
        let active = states.compactMap { $0 }.filter(\.isActive).count
        header = NSAttributedString(string: CmuxStrings.planHeader(steps: card.rows.count, active: active),
                                    attributes: [.font: HomeFonts.system(ofSize: 12, weight: .semibold), .foregroundColor: Fixture.secondaryText])
        let small = HomeFonts.system(ofSize: 11)
        lines = card.rows.enumerated().map { i, row in
            let title = NSAttributedString(string: row.title, attributes: [.font: Fixture.bodyFont, .foregroundColor: Fixture.incomingText])
            var bits: [String] = []
            if let key = row.key { bits.append(key) }
            if let note = row.ownerNote { bits.append(note) }
            bits += row.pullRequests.compactMap { ChiefPlanPullRequest(link: $0).map { "#\($0.number)" } }
            let detail = bits.isEmpty ? nil : NSAttributedString(string: bits.joined(separator: " · "),
                                                                 attributes: [.font: small, .foregroundColor: Fixture.secondaryText])
            return Line(owner: row.owner, title: title, detail: detail,
                        titleHeight: HomeTableGrid.textHeight(title, width: textWidth),
                        detailHeight: detail.map { HomeTableGrid.textHeight($0, width: textWidth) } ?? 0,
                        state: states[checked: i] ?? nil)
        }
    }

    func draw(_ ctx: CGContext, at origin: CGPoint) {
        let card = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        HomeCardDraw.background(ctx, card)
        var y = card.minY + Self.pad
        HomeCardDraw.text(ctx, header, in: CGRect(x: card.minX + Self.pad, y: y, width: card.width - 2 * Self.pad, height: headerHeight), alignment: .leading)
        y += headerHeight
        for (i, line) in lines.enumerated() {
            HomeCardDraw.hairline(ctx, from: CGPoint(x: card.minX + Self.pad, y: y), to: CGPoint(x: card.maxX - Self.pad, y: y), strong: i == 0)
            let top = y + Self.rowPadY
            if let owner = line.owner {
                HomeCardDraw.pill(ctx, owner, in: CGRect(x: card.minX + Self.pad, y: top, width: Self.chipWidth - 8, height: 18), trailing: false,
                                  fill: Fixture.incomingLink.withAlphaComponent(0.18), text: Fixture.incomingLink)
            }
            let x = card.minX + Self.pad + Self.chipWidth
            HomeCardDraw.text(ctx, line.title, in: CGRect(x: x, y: top, width: textWidth, height: line.titleHeight), alignment: .leading)
            if let detail = line.detail {
                HomeCardDraw.text(ctx, detail, in: CGRect(x: x, y: top + line.titleHeight + Self.lineGap, width: textWidth, height: line.detailHeight),
                                  alignment: .leading)
            }
            if let state = line.state {
                let tint = HomeCardDraw.tint(state)
                HomeCardDraw.pill(ctx, CmuxStrings.planState(state), in: CGRect(x: card.maxX - Self.pad - Self.pillWidth, y: top, width: Self.pillWidth, height: 18),
                                  trailing: true, fill: tint.withAlphaComponent(0.18), text: tint)
            }
            y += Self.rowHeight(line)
        }
    }
}

/// Drawing shared by the table and plan cards, in the row bitmap's y-down context. Any thread.
enum HomeCardDraw {
    static func background(_ ctx: CGContext, _ rect: CGRect) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setFillColor(Fixture.incoming.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func hairline(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, strong: Bool) {
        ctx.saveGState()
        ctx.setStrokeColor(Fixture.secondaryText.withAlphaComponent(strong ? 0.45 : 0.22).cgColor)
        ctx.setLineWidth(strong ? 1 : 0.5)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()
    }

    struct Line {
        var line: CTLine
        var width: CGFloat
        var ascent: CGFloat
        var height: CGFloat
    }

    /// `text` wrapped at `width`: each line with its width, ascent and height (rounded up). Measure
    /// (``HomeTableGrid/textHeight(_:width:)``) and draw both use it, so a cell is as tall as it draws.
    static func lines(_ text: NSAttributedString, width: CGFloat) -> [Line] {
        guard text.length > 0 else { return [] }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: max(1, width), height: 100_000), transform: nil), nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return [] }
        return lines.map { line in
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            return Line(line: line, width: w, ascent: ascent, height: (ascent + descent + leading).rounded(.up))
        }
    }

    /// `text` wrapped into `rect` (top-left origin, y down).
    static func text(_ ctx: CGContext, _ text: NSAttributedString, in rect: CGRect, alignment: HomeTable.Alignment) {
        guard rect.width > 0 else { return }
        var y = rect.minY
        for line in lines(text, width: rect.width) {
            let x: CGFloat = switch alignment {
            case .leading: rect.minX
            case .center: rect.midX - line.width / 2
            case .trailing: rect.maxX - line.width
            }
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: x, y: y + line.ascent)
            CTLineDraw(line.line, ctx)
            ctx.restoreGState()
            y += line.height
        }
    }

    /// A rounded label as wide as its text (at most `rect`), at `rect`'s trailing or leading edge.
    static func pill(_ ctx: CGContext, _ label: String, in rect: CGRect, trailing: Bool, fill: UIColor, text color: UIColor) {
        let font = HomeFonts.system(ofSize: 11, weight: .semibold)
        let s = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        let w = min(rect.width, HomeTableGrid.lineWidth(s) + 14)
        let pill = CGRect(x: trailing ? rect.maxX - w : rect.minX, y: rect.minY, width: w, height: rect.height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        text(ctx, s, in: pill.insetBy(dx: 7, dy: 2), alignment: .center)
    }

    /// Fixed sRGB tints (a system colour's cgColor off the main thread can resolve to its light variant).
    static func tint(_ state: ChiefPlanStep.State) -> UIColor {
        switch state {
        case .working: UIColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
        case .needsInput: UIColor(srgbRed: 0.95, green: 0.72, blue: 0.05, alpha: 1)
        case .waitingOnCI: UIColor(srgbRed: 1, green: 0.58, blue: 0.04, alpha: 1)
        case .ciFailed, .failed: UIColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
        case .inReview: UIColor(srgbRed: 0.69, green: 0.38, blue: 0.95, alpha: 1)
        case .landed: UIColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)
        case .done: UIColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        }
    }
}

/// A click on a table or plan card: a menu of its links at the pointer (the row is drawn, so it has
/// no per-link hit areas). Main thread.
enum HomeCardLinks {
    static func title(_ url: URL) -> String {
        if let pr = ChiefPlanPullRequest(link: url.absoluteString) { return CmuxStrings.planOpenLink("#\(pr.number)") }
        return CmuxStrings.planOpenLink(url.host ?? url.absoluteString)
    }

    /// Shows the menu of `items` (without repeats) at the pointer.
    @MainActor static func offer(_ items: [(String, URL)]) {
        var seen = Set<URL>()
        let unique = items.filter { seen.insert($0.1).inserted }
        guard !unique.isEmpty else { return }
        let menu = NSMenu()
        for (title, url) in unique.prefix(24) {
            let item = NSMenuItem(title: title, action: #selector(HomeCardLinkTarget.open(_:)), keyEquivalent: "")
            item.target = HomeCardLinkTarget.shared
            item.representedObject = url
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

@MainActor final class HomeCardLinkTarget: NSObject {
    static let shared = HomeCardLinkTarget()
    @objc func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
}
