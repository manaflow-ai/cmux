import AppKit
import CmuxHomeRender

/// A failed Chief turn's card in the Home transcript (``HomeTurnFailure``): the plain-words
/// sentence, then Retry (the Chief answers the person's message again), Copy error and Details,
/// which opens the raw failure line under them. Drawn into the row bitmap like the approval card.
final class HomeTurnFailureRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.turnFailure"

    /// The card's buttons.
    enum Action: String, Codable, Sendable { case retry, copy, details }

    /// The view's own state of one card (``HomeProjection`` keeps it per message).
    struct Local: Codable, Equatable, Sendable {
        var open = false
        var copied = false
        /// The Chief can answer again: a person's message comes before the card and retry is wired.
        var retry = false
    }

    struct Payload: Codable, Equatable {
        var title: String
        var detail: String
        var local: Local
    }

    @MainActor static func install() {
        if CustomRows.provider(kind) == nil { CustomRows.register(HomeTurnFailureRowProvider()) }
    }

    static func part(_ failure: HomeTurnFailure, local: Local = .init()) -> Part? {
        custom(Payload(title: failure.title, detail: failure.detail, local: local)).map { .custom($0) }
    }

    static func custom(_ payload: Payload) -> CustomPart? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return CustomPart(kind: kind, version: HomeDiagramRowProvider.version(String(decoding: data, as: UTF8.self)), payload: data)
    }

    static func payload(_ part: CustomPart) -> Payload? { part.kind == kind ? part.decode(Payload.self) : nil }

    // MARK: Layout

    static let buttonGap: CGFloat = 14
    static let rowGap: CGFloat = 4
    static var detailFont: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }

    struct Layout {
        let title: TextLayout
        let detail: TextLayout?
        let buttons: [(Action, String, CGRect)]
        let detailTop: CGFloat
        let size: CGSize
    }

    static func titles(_ p: Payload) -> [(Action, String)] {
        var titles: [(Action, String)] = []
        if p.local.retry { titles.append((.retry, CmuxStrings.turnFailureRetry)) }
        titles.append((.copy, p.local.copied ? CmuxStrings.turnFailureCopied : CmuxStrings.turnFailureCopy))
        titles.append((.details, p.local.open ? CmuxStrings.turnFailureHideDetails : CmuxStrings.turnFailureDetails))
        return titles
    }

    static func layout(_ p: Payload, width: CGFloat) -> Layout {
        let pad = Fixture.bubblePadX
        let titleLayout = TextLayout.make(p.title, runs: [], maxWidth: max(1, min(420, width) - 2 * pad))
        var buttons: [(Action, String, CGRect)] = []
        var x = pad
        let buttonTop = Fixture.bubblePadY + titleLayout.textHeight(hard: Fixture.lineHeight) + rowGap
        for (action, title) in titles(p) {
            let w = ceil(TextDraw.width(title, font: Fixture.bodyFont))
            buttons.append((action, title, CGRect(x: x, y: buttonTop, width: w, height: Fixture.lineHeight)))
            x += w + buttonGap
        }
        var height = buttonTop + Fixture.lineHeight
        var detail: TextLayout?
        let detailTop = height + rowGap
        if p.local.open {
            let d = TextLayout.make(p.detail, runs: [], maxWidth: max(1, min(420, width) - 2 * pad), font: detailFont)
            detail = d
            height = detailTop + CGFloat(d.lines.count) * 14
        }
        let contentWidth = max(titleLayout.width + 2 * pad, x - buttonGap + pad, detail.map { $0.width + 2 * pad } ?? 0)
        return Layout(title: titleLayout, detail: detail, buttons: buttons, detailTop: detailTop,
                      size: CGSize(width: min(max(80, min(420, width)), ceil(contentWidth)), height: ceil(height + Fixture.bubblePadY)))
    }

    /// The button at `point` (the row body's top-left origin), if any.
    static func action(at point: CGPoint, _ p: Payload, width: CGFloat) -> Action? {
        layout(p, width: width).buttons.first { $0.2.insetBy(dx: -4, dy: -3).contains(point) }?.0
    }

    // MARK: TranscriptCustomRowProvider

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .bubbleIncoming }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func plainText(_ part: CustomPart) -> String? { Self.payload(part).map { "\($0.title)\n\n\($0.detail)" } }
    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        Self.payload(part).map { Self.layout($0, width: maxWidth).size } ?? .zero
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let p = Self.payload(part) else { return }
        let layout = Self.layout(p, width: rect.width)
        PartRenderer.drawText(ctx, layout.title, in: rect, outgoing: false)
        let font = Fixture.bodyFont
        for (_, title, frame) in layout.buttons {
            TextDraw.line(title, font: font, color: Fixture.incomingLink, x: rect.minX + frame.minX,
                          baseline: rect.minY + frame.minY + 12, in: ctx)
        }
        guard let detail = layout.detail else { return }
        let ns = detail.text as NSString
        for (i, line) in detail.lines.enumerated() where line.range.length > 0 {
            TextDraw.line(ns.substring(with: line.range), font: Self.detailFont, color: Fixture.secondaryText,
                          x: rect.minX + Fixture.bubblePadX, baseline: rect.minY + layout.detailTop + 11 + CGFloat(i) * 14, in: ctx)
        }
    }
}
