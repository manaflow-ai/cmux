import CmuxHomeCore
import CmuxHomeRender
import CoreGraphics
import Foundation
import os

/// cmux: chat widgets (plans/cmux-next/chat-widgets-DESIGN.md) as a drawn custom row
/// (CustomRows.swift, `Part.custom` of kind ``kind``).
///
/// An agent's `widget` part maps to one bubble of this kind. Its payload holds the widget's
/// current ``HomeWidgetSnapshot`` from the host (``HomeWidgetHosting``: the Mac app's app host
/// runs the app's `cmux.chat.widget/1` export), so the row measures and draws off the main
/// thread like any bubble, natively: rows, text, buttons and badges in the transcript's palette,
/// no web view. Without a host, before the first scene and when the app is missing, the bubble is
/// the part's fallback text. A click on a row or button goes back to the host as a tap on its
/// scene node (the app runs `cmux.actions.run` only with its granted `actions:run` scope).
final class HomeWidgetRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.widget"

    struct Payload: Codable, Equatable {
        var key: String
        var fallback: String
        var snapshot: HomeWidgetSnapshot?
    }

    /// Set once at install, on main; read only on main (the projection, `tapped`).
    private(set) weak var host: (any HomeWidgetHosting)?
    private let symbols = HomeWidgetSymbols()
    /// Each shown widget's latest snapshot, by key: the projection writes it on main from the host,
    /// and the mapping reads it wherever it maps parts.
    // Lock carve-out: `part(_:key:)` is a synchronous read from the mapping (any thread); a small map.
    private let snapshots = OSAllocatedUnfairLock<[String: HomeWidgetSnapshot]>(initialState: [:])

    init(host: (any HomeWidgetHosting)?) {
        self.host = host
    }

    /// The registered provider (nil: widget parts show their fallback text).
    static var installed: HomeWidgetRowProvider? { CustomRows.provider(kind) as? HomeWidgetRowProvider }

    /// Registers the widget rows over `host` (once per host).
    @MainActor static func install(_ host: any HomeWidgetHosting) {
        guard installed?.host !== host else { return }
        CustomRows.register(HomeWidgetRowProvider(host: host))
    }

    /// The bubble for `widget` at `key` (`<message id>#<part index>`), with its latest snapshot.
    func part(_ widget: ChatWidget, key: String) -> Part? {
        Self.custom(Payload(key: key, fallback: widget.fallback, snapshot: snapshots.withLock { $0[key] }))
    }

    /// Records `snapshot` for `key`; true when it changed.
    @discardableResult
    func store(_ snapshot: HomeWidgetSnapshot?, for key: String) -> Bool {
        snapshots.withLock { map in
            guard map[key] != snapshot else { return false }
            map[key] = snapshot
            return true
        }
    }

    /// Drops the snapshots of widgets no transcript shows.
    func forget(except keys: Set<String>) {
        snapshots.withLock { map in map = map.filter { keys.contains($0.key) } }
    }

    /// `<message id>#<part index>`: the widget's mount and storage key.
    static func key(_ item: TranscriptItem, part index: Int) -> String {
        "\(item.messageID?.rawValue ?? item.key.rawValue)#\(index)"
    }

    static func custom(_ payload: Payload) -> Part? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return .custom(CustomPart(kind: kind, version: HomeDiagramRowProvider.version(String(decoding: data, as: UTF8.self)), payload: data))
    }

    static func payload(_ part: CustomPart) -> Payload? { part.kind == kind ? part.decode(Payload.self) : nil }

    // MARK: TranscriptCustomRowProvider

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .bubbleIncoming }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func plainText(_ part: CustomPart) -> String? { Self.payload(part)?.fallback }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let p = Self.payload(part) else { return .zero }
        guard let snapshot = p.snapshot else { return Self.fallbackSize(p.fallback, maxWidth: maxWidth) }
        return HomeWidgetLayout(snapshot, width: maxWidth).size
    }

    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }

    func tapped(_ part: CustomPart, ref: PartRef, at point: CGPoint, width: CGFloat) -> Bool {
        guard let p = Self.payload(part), let snapshot = p.snapshot,
              let node = HomeWidgetLayout(snapshot, width: width).node(at: point) else { return false }
        MainActor.assumeIsolated { host?.tap(key: p.key, node: node) }
        return true
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let p = Self.payload(part) else { return }
        guard let snapshot = p.snapshot else {
            let text = TextLayout.make(p.fallback, runs: [], maxWidth: max(1, rect.width - 2 * Fixture.bubblePadX))
            PartRenderer.drawText(ctx, text, in: rect, outgoing: false)
            return
        }
        let layout = HomeWidgetLayout(snapshot, width: rect.width)
        for placed in layout.placed {
            draw(placed, in: ctx, origin: rect.origin)
        }
    }

    // MARK: Drawing

    private static func fallbackSize(_ text: String, maxWidth: CGFloat) -> CGSize {
        let width = max(80, min(HomeWidgetLayout.maxWidth, maxWidth))
        let layout = TextLayout.make(text, runs: [], maxWidth: max(1, width - 2 * Fixture.bubblePadX))
        return CGSize(width: min(width, layout.width + 2 * Fixture.bubblePadX),
                      height: layout.textHeight(hard: Fixture.lineHeight) + 2 * Fixture.bubblePadY)
    }

    private func draw(_ placed: HomeWidgetLayout.Placed, in ctx: CGContext, origin: CGPoint) {
        let frame = placed.frame.offsetBy(dx: origin.x, dy: origin.y)
        switch placed.item {
        case let .text(_, style, tint):
            let height = HomeWidgetStyle.lineHeight(style)
            let font = HomeWidgetStyle.font(style)
            for (index, line) in placed.lines.enumerated() {
                let top = frame.minY + CGFloat(index) * height
                Self.drawLine(line, color: HomeWidgetStyle.color(tint), x: frame.minX,
                              baseline: top + (height + font.ascender + font.descender) / 2, ctx: ctx)
            }
        case let .row(_, title, subtitle, symbol, tint, badge):
            var x = frame.minX
            if let symbol {
                symbols.draw(symbol, in: CGRect(x: x, y: frame.midY - 8, width: 16, height: 16), color: HomeWidgetStyle.color(tint), ctx: ctx)
                x += 24
            }
            var right = frame.maxX
            if let badge, !badge.isEmpty {
                let width = TextDraw.width(badge, font: HomeWidgetStyle.badgeFont) + 12
                let pill = CGRect(x: right - width, y: frame.midY - 9, width: width, height: 18)
                drawBadge(badge, in: pill, tint: tint, ctx: ctx)
                right = pill.minX - 8
            }
            let width = max(1, right - x)
            let titleFont = HomeWidgetStyle.rowTitleFont, subtitleFont = HomeWidgetStyle.rowSubtitleFont
            let hasSubtitle = !(subtitle ?? "").isEmpty
            let titleBaseline = hasSubtitle ? frame.minY + 15 : frame.midY + (titleFont.ascender + titleFont.descender) / 2
            Self.drawTruncated(title, font: titleFont, color: Fixture.incomingText, x: x, baseline: titleBaseline, width: width, ctx: ctx)
            if let subtitle, hasSubtitle {
                Self.drawTruncated(subtitle, font: subtitleFont, color: Fixture.secondaryText, x: x, baseline: frame.minY + 29,
                                   width: width, ctx: ctx)
            }
        case .buttons:
            for (button, local) in placed.buttons {
                let r = local.offsetBy(dx: origin.x, dy: origin.y)
                let accent = HomeWidgetStyle.color(.accent)
                let fill = button.prominent ? accent : HomeWidgetStyle.wash(Fixture.incomingText)
                ctx.setFillColor(fill.withAlphaComponent(fill.alphaComponent * (button.enabled ? 1 : 0.5)).cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.fillPath()
                let font = HomeWidgetStyle.buttonFont
                let ink = (button.prominent ? UIColor.white : Fixture.incomingText).withAlphaComponent(button.enabled ? 1 : 0.45)
                let width = min(r.width - 12, TextDraw.width(button.title, font: font))
                Self.drawTruncated(button.title, font: font, color: ink, x: r.midX - width / 2,
                                   baseline: r.midY + (font.ascender + font.descender) / 2, width: r.width - 12, ctx: ctx)
            }
        case let .badge(text, tint):
            drawBadge(text, in: frame, tint: tint, ctx: ctx)
        case .divider:
            ctx.setFillColor(HomeWidgetStyle.wash(Fixture.incomingText, 0.14).cgColor)
            ctx.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 0.5))
        case let .empty(title, message, symbol):
            var y = frame.minY + 4
            if let symbol {
                symbols.draw(symbol, in: CGRect(x: frame.midX - 10, y: y, width: 20, height: 20), color: Fixture.secondaryText, ctx: ctx)
                y += 26
            }
            Self.drawCentered(title, font: HomeWidgetStyle.rowTitleFont, color: Fixture.incomingText, midX: frame.midX,
                              baseline: y + 12, width: frame.width, ctx: ctx)
            if let message {
                Self.drawCentered(message, font: HomeWidgetStyle.captionFont, color: Fixture.secondaryText, midX: frame.midX,
                                  baseline: y + 28, width: frame.width, ctx: ctx)
            }
        }
    }

    private func drawBadge(_ text: String, in rect: CGRect, tint: HomeWidgetSnapshot.Tint, ctx: CGContext) {
        let color = HomeWidgetStyle.color(tint)
        ctx.setFillColor(HomeWidgetStyle.wash(color, 0.16).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.fillPath()
        let font = HomeWidgetStyle.badgeFont
        Self.drawTruncated(text, font: font, color: color, x: rect.minX + 6, baseline: rect.midY + (font.ascender + font.descender) / 2,
                           width: rect.width - 12, ctx: ctx)
    }

    private static func drawLine(_ line: CTLine, color: UIColor, x: CGFloat, baseline: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        // The lines carry no color attribute: CTLineDraw fills with the context's fill color.
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawTruncated(_ text: String, font: UIFont, color: UIColor, x: CGFloat, baseline: CGFloat, width: CGFloat,
                                      ctx: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
        let shown = CTLineCreateTruncatedLine(line, Double(max(1, width)), .end, ellipsis) ?? line
        drawLine(shown, color: color, x: x, baseline: baseline, ctx: ctx)
    }

    private static func drawCentered(_ text: String, font: UIFont, color: UIColor, midX: CGFloat, baseline: CGFloat, width: CGFloat,
                                     ctx: CGContext) {
        let shownWidth = min(width, TextDraw.width(text, font: font))
        drawTruncated(text, font: font, color: color, x: midX - shownWidth / 2, baseline: baseline, width: width, ctx: ctx)
    }
}
