import AppKit
import CmuxHomeCore
import CoreGraphics
import CoreText
import Foundation
import os

/// cmux issue 25830: a Chief's `card` part as a drawn row (CustomRows.swift) in an incoming bubble,
/// like the table and plan cards (``HomeTableRowProvider``). Three kinds:
/// - browser: an icon tile (globe for the browser, a display for the computer), the title and the
///   current step, the screenshot in a white inset, and "Open browser" when the card names a target.
///   The Chief edits one card per turn, so the row updates in place as the message is edited.
/// - sign_in: a shield tile, "Secure Store", "Sign in to <site>" and a white Add button; "Added" once
///   this Mac's Secure Store holds the site (``HomeChiefCardState``).
/// - next_steps: one outlined row per choice with a circle check at its right; a click sends the
///   choice as a person message; a choice a later person message said is checked and takes no click.
/// The row is drawn, so it has no per-control views: a click maps to an action through the same
/// layout the drawing used (``HomeChiefCardLayout/action(at:)``), and copy and VoiceOver read the
/// card's text with its button names (``plainText(_:)``).
final class HomeChiefCardRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.chiefCard"

    /// The card and what this Mac shows for it beside the owner's part.
    struct Payload: Codable, Hashable {
        var card: ChiefCard
        /// The screenshot's picture (`HomeMedia.asset`), nil until it is ready.
        var picture: String?
        /// The choices a later person message said, in the card's order.
        var chosen: [String]
        /// The Secure Store holds the sign-in card's site.
        var added: Bool
    }

    /// The registered provider (nil: cards map as their text).
    static var installed: HomeChiefCardRowProvider? { CustomRows.provider(kind) as? HomeChiefCardRowProvider }

    /// Registers the card provider once per process.
    static func install() {
        if installed == nil { CustomRows.register(HomeChiefCardRowProvider()) }
    }

    /// The row for `card`: a drawn card when the provider is installed, else its text. `context`: what
    /// only this Mac knows (``HomeChiefCardContext``; empty in the mappings that do not have it).
    static func part(_ card: ChiefCard, media: HomeMapping.Media, context: HomeChiefCardContext) -> Part {
        let payload = Payload(card: card, picture: card.image.flatMap { media($0.hash) },
                              chosen: card.choices.filter(context.chosen.contains),
                              added: card.kind == .signIn && card.site.map(context.holds) == true)
        guard installed != nil, let custom = custom(payload) else { return .text(HomeChiefCards.text(payload), runs: []) }
        return .custom(custom)
    }

    static func custom(_ payload: Payload) -> CustomPart? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(payload) else { return nil }
        // The version follows the content: a new step, picture, choice or Added redraws the row.
        return CustomPart(kind: kind, version: HomeDiagramRowProvider.version(String(decoding: data, as: UTF8.self)), payload: data)
    }

    static func payload(_ part: CustomPart) -> Payload? { part.kind == kind ? part.decode(Payload.self) : nil }

    /// What a click at `point` (in the row's body, top-left origin) does on card `part` drawn `width` wide.
    static func action(_ part: CustomPart, at point: CGPoint, width: CGFloat) -> HomeChiefCardAction? {
        guard let payload = payload(part) else { return nil }
        return HomeChiefCardLayout(payload, width: width).action(at: point)
    }

    // MARK: TranscriptCustomRowProvider

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .bubbleIncoming }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func plainText(_ part: CustomPart) -> String? { Self.payload(part).map(HomeChiefCards.text) }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let payload = Self.payload(part) else { return CGSize(width: maxWidth, height: 24) }
        let layout = HomeChiefCardLayout(payload, width: HomeChiefCardLayout.width(payload, maxWidth: maxWidth))
        return CGSize(width: layout.width, height: layout.height)
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let payload = Self.payload(part) else { return }
        HomeChiefCardLayout(payload, width: rect.width).draw(ctx, at: rect.origin, icons: icons)
    }

    /// The tile symbols this provider drew (row bitmaps draw on their threads).
    private let icons = HomeChiefCardIcons()
}

/// What a click on a card asks the host for.
enum HomeChiefCardAction: Equatable {
    /// "Open browser": the browser right of the Home chat, or a Cloud machine's desktop.
    case open(ChiefCard.Target, url: String?)
    /// "Add": the sign-in sheet for `site`; a saved sign-in sends the Added message.
    case addSignIn(site: String, url: String?)
    /// A next-step chip: its text goes as a person message.
    case choose(String)
}

/// What a card shows that no message carries: the chips a later person message said, and the
/// sites this Mac's Secure Store holds (lowercased).
struct HomeChiefCardContext: Hashable {
    var chosen: Set<String> = []
    var stored: Set<String> = []

    /// Whether the Secure Store holds a login `site` (a card's host) uses: as
    /// `ChiefSecureStore.credential(forHost:)` matches, the stored site itself or a parent domain of
    /// it (a card for `www.linkedin.com` shows Added when `linkedin.com` is saved).
    func holds(_ site: String) -> Bool {
        guard let host = Self.normalized(site) else { return false }
        return stored.contains { stored in
            guard let stored = Self.normalized(stored) else { return false }
            return host == stored || host.hasSuffix("." + stored)
        }
    }

    /// Lowercased with a trailing dot dropped; nil when empty.
    private static func normalized(_ name: String) -> String? {
        var name = name.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }
}

/// The cards' words and the chips' derivation.
enum HomeChiefCards {
    /// For each item with a next-steps card (by its key), the choices a later person message said.
    /// One pass from the newest item back (a person's texts so far, then each card against them).
    static func chosen(in items: [TranscriptItem], isPerson: (ParticipantID) -> Bool) -> [IdempotencyKey: Set<String>] {
        var later: Set<String> = []
        var found: [IdempotencyKey: Set<String>] = [:]
        for item in items.reversed() where !item.isRetracted {
            for case .card(let card) in item.parts where card.kind == .nextSteps {
                let picked = ChiefCard.chosen(card.choices, laterPersonTexts: later)
                if !picked.isEmpty { found[item.key] = picked }
            }
            if isPerson(item.author) {
                for case .text(let text, _) in item.parts { later.insert(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        return found
    }

    /// The message a saved sign-in sends: it wakes the Chief, which fills the page from the store.
    static func signInAddedMessage(_ site: String) -> String { CmuxStrings.chiefCardSignInAddedMessage(site) }

    /// The card as text with its button names (copy, VoiceOver, hosts without drawn rows).
    static func text(_ payload: HomeChiefCardRowProvider.Payload) -> String {
        let card = payload.card
        switch card.kind {
        case .browser:
            let title = card.surface == .computer ? CmuxStrings.chiefCardComputer : CmuxStrings.chiefCardBrowser
            var lines = ["\(title): \(card.step ?? "")"]
            if card.openTarget != nil { lines.append(HomeChiefCardLayout.openTitle(card)) }
            return lines.joined(separator: "\n")
        case .signIn:
            let state = payload.added ? CmuxStrings.chiefCardSignInAdded : CmuxStrings.chiefCardSignInAdd
            return [CmuxStrings.chiefCardSecureStore, CmuxStrings.chiefCardSignInTo(card.site ?? ""), state].joined(separator: "\n")
        case .nextSteps:
            return card.choices.map { payload.chosen.contains($0) ? CmuxStrings.chiefCardChoiceSent($0) : "→ \($0)" }
                .joined(separator: "\n")
        }
    }
}

/// One card laid out at its width: measure, draw and click all use it, so a click lands on what
/// was drawn. Pure CoreText and CoreGraphics, any thread. Body coordinates, top-left origin, y down.
struct HomeChiefCardLayout {
    static let pad: CGFloat = 12
    static let tile: CGFloat = 32
    static let gap: CGFloat = 10
    static let buttonHeight: CGFloat = 30
    static let chipGap: CGFloat = 6
    static let chipInset: CGFloat = 8
    static let check: CGFloat = 20
    static let maxSteps = 3
    /// Widest card (a browser card or next steps); a sign-in card is narrower, as in the reference.
    static let wideWidth: CGFloat = 420
    static let signInWidth: CGFloat = 300

    struct Chip {
        var text: String
        var frame: CGRect
        var lines: [HomeCardDraw.Line]
        var textOrigin: CGPoint
        var check: CGRect
        var chosen: Bool
    }

    let payload: HomeChiefCardRowProvider.Payload
    let width: CGFloat
    private(set) var height: CGFloat = 0
    private(set) var tileRect: CGRect = .zero
    private(set) var title: [HomeCardDraw.Line] = []
    private(set) var subtitle: [HomeCardDraw.Line] = []
    private(set) var titleOrigin: CGPoint = .zero
    private(set) var picture: CGRect?
    private(set) var button: CGRect?
    private(set) var chips: [Chip] = []

    static func width(_ payload: HomeChiefCardRowProvider.Payload, maxWidth: CGFloat) -> CGFloat {
        min(maxWidth, payload.card.kind == .signIn ? signInWidth : wideWidth).rounded()
    }

    static var titleFont: UIFont { HomeFonts.system(ofSize: Fixture.bodyFont.pointSize, weight: .semibold) }
    static var bodyFont: UIFont { Fixture.bodyFont }
    static var buttonFont: UIFont { HomeFonts.system(ofSize: Fixture.bodyFont.pointSize, weight: .medium) }

    static func openTitle(_ card: ChiefCard) -> String {
        card.surface == .computer ? CmuxStrings.chiefCardOpenDesktop : CmuxStrings.chiefCardOpenBrowser
    }

    init(_ payload: HomeChiefCardRowProvider.Payload, width: CGFloat) {
        self.payload = payload
        self.width = width
        let card = payload.card
        let inner = max(1, width - 2 * Self.pad)
        var y = Self.pad
        switch card.kind {
        case .browser, .signIn:
            tileRect = CGRect(x: Self.pad, y: y, width: Self.tile, height: Self.tile)
            let textX = Self.pad + Self.tile + Self.gap
            let textWidth = max(1, width - textX - Self.pad)
            let (heading, line) = card.kind == .browser
                ? (card.surface == .computer ? CmuxStrings.chiefCardComputer : CmuxStrings.chiefCardBrowser, card.step ?? "")
                : (CmuxStrings.chiefCardSecureStore, CmuxStrings.chiefCardSignInTo(card.site ?? ""))
            title = Array(HomeCardDraw.lines(Self.attributed(heading, Self.titleFont, Fixture.incomingText), width: textWidth).prefix(1))
            subtitle = Array(HomeCardDraw.lines(Self.attributed(line, Self.bodyFont, Fixture.secondaryText), width: textWidth).prefix(Self.maxSteps))
            let textHeight = (title + subtitle).reduce(0) { $0 + $1.height }
            let header = max(Self.tile, textHeight)
            titleOrigin = CGPoint(x: textX, y: y + (header - textHeight) / 2)
            y += header + Self.gap
            if card.kind == .browser, let image = card.image {
                let aspect: CGFloat = if let w = image.width, let h = image.height, w > 0, h > 0 { CGFloat(h) / CGFloat(w) } else { 10.0 / 16.0 }
                let h = min(max(inner * aspect, 80), 320).rounded()
                picture = CGRect(x: Self.pad, y: y, width: inner, height: h)
                y += h + Self.gap
            }
            if card.kind == .signIn || card.openTarget != nil {
                button = CGRect(x: Self.pad, y: y, width: inner, height: Self.buttonHeight)
                y += Self.buttonHeight + Self.gap
            }
            height = (y - Self.gap + Self.pad).rounded(.up)
        case .nextSteps:
            y = Self.chipInset
            let chipWidth = max(1, width - 2 * Self.chipInset)
            for choice in card.choices {
                let chosen = payload.chosen.contains(choice)
                let textWidth = max(1, chipWidth - 12 - Self.check - 20)
                let color = chosen ? Fixture.secondaryText : Fixture.incomingText
                let lines = HomeCardDraw.lines(Self.attributed(choice, Self.bodyFont, color), width: textWidth)
                let textHeight = lines.reduce(0) { $0 + $1.height }
                let h = max(34, (textHeight + 16).rounded(.up))
                let frame = CGRect(x: Self.chipInset, y: y, width: chipWidth, height: h)
                let check = CGRect(x: frame.maxX - 10 - Self.check, y: frame.midY - Self.check / 2, width: Self.check, height: Self.check)
                chips.append(Chip(text: choice, frame: frame, lines: lines,
                                  textOrigin: CGPoint(x: frame.minX + 12, y: frame.minY + (h - textHeight) / 2), check: check, chosen: chosen))
                y += h + Self.chipGap
            }
            height = (y - Self.chipGap + Self.chipInset).rounded(.up)
        }
    }

    static func attributed(_ text: String, _ font: UIFont, _ color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// The click's action; nil off a control or on a disabled one (Added, a chosen chip).
    func action(at p: CGPoint) -> HomeChiefCardAction? {
        let card = payload.card
        switch card.kind {
        case .browser:
            guard let button, button.insetBy(dx: 0, dy: -3).contains(p), let target = card.openTarget else { return nil }
            return .open(target, url: card.url)
        case .signIn:
            guard let button, button.insetBy(dx: 0, dy: -3).contains(p), !payload.added, let site = card.site else { return nil }
            return .addSignIn(site: site, url: card.url)
        case .nextSteps:
            guard let chip = chips.first(where: { $0.frame.insetBy(dx: 0, dy: -Self.chipGap / 2).contains(p) }), !chip.chosen else { return nil }
            return .choose(chip.text)
        }
    }

    // MARK: Drawing

    private var light: Bool { Fixture.lightAppearance }

    func draw(_ ctx: CGContext, at origin: CGPoint, icons: HomeChiefCardIcons) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: origin.x, y: origin.y)
        let card = payload.card
        switch card.kind {
        case .browser, .signIn:
            drawTile(ctx, card, icons: icons)
            var y = titleOrigin.y
            for line in title + subtitle {
                Self.drawLine(ctx, line, at: CGPoint(x: titleOrigin.x, y: y))
                y += line.height
            }
            if let picture { drawPicture(ctx, picture) }
            if let button { drawButton(ctx, button, card) }
        case .nextSteps:
            for chip in chips { drawChip(ctx, chip) }
        }
    }

    private func drawTile(_ ctx: CGContext, _ card: ChiefCard, icons: HomeChiefCardIcons) {
        let browser = card.kind == .browser
        let blue = UIColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
        let fill: UIColor = browser
            ? (light ? UIColor(srgbRed: 0.87, green: 0.93, blue: 1, alpha: 1) : blue.withAlphaComponent(0.22))
            : (light ? UIColor(white: 1, alpha: 1) : UIColor(white: 1, alpha: 0.12))
        Self.fillRounded(ctx, tileRect, radius: 8, fill)
        let symbol = browser ? (card.surface == .computer ? "display" : "globe") : "lock.shield"
        let tint = browser ? blue : Fixture.secondaryText
        if let icon = icons.image(symbol, size: 15, color: tint, scale: Fixture.renderScale) {
            Self.drawCentered(ctx, icon, in: tileRect, scale: Fixture.renderScale)
        }
    }

    private func drawPicture(_ ctx: CGContext, _ rect: CGRect) {
        Self.fillRounded(ctx, rect, radius: 10, light ? UIColor(white: 1, alpha: 1) : UIColor(white: 1, alpha: 0.08))
        guard let asset = payload.picture, let image = Images.load(asset)?.cgImage else { return }
        // The whole page, aspect fit, in the rounded inset.
        let box = rect.insetBy(dx: 4, dy: 4)
        let s = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.clip()
        Self.drawImage(ctx, image, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    private func drawButton(_ ctx: CGContext, _ rect: CGRect, _ card: ChiefCard) {
        let radius = rect.height / 2
        if card.kind == .signIn {
            Self.fillRounded(ctx, rect, radius: radius, light ? UIColor(white: 1, alpha: payload.added ? 0.6 : 1) : UIColor(white: 1, alpha: 0.14))
        } else {
            Self.fillRounded(ctx, rect, radius: radius, light ? UIColor(white: 1, alpha: 0.55) : UIColor(white: 1, alpha: 0.09))
        }
        let (label, color): (String, UIColor) = switch card.kind {
        case .signIn where payload.added: (CmuxStrings.chiefCardSignInAdded, Fixture.secondaryText)
        case .signIn: (CmuxStrings.chiefCardSignInAdd, Fixture.incomingText)
        default: (Self.openTitle(card), Fixture.incomingText)
        }
        guard let line = HomeCardDraw.lines(Self.attributed(label, Self.buttonFont, color), width: rect.width - 2 * radius).first else { return }
        let checkWidth: CGFloat = card.kind == .signIn && payload.added ? 16 : 0
        let x = rect.midX - (line.width + checkWidth) / 2
        if checkWidth > 0 {
            Self.strokeCheck(ctx, in: CGRect(x: x, y: rect.midY - 5, width: 10, height: 10), color: color, width: 1.6)
        }
        Self.drawLine(ctx, line, at: CGPoint(x: x + checkWidth, y: rect.midY - line.height / 2))
    }

    private func drawChip(_ ctx: CGContext, _ chip: Chip) {
        let ink = Fixture.incomingText
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: chip.frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.setStrokeColor(ink.withAlphaComponent(chip.chosen ? 0.3 : 0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
        var y = chip.textOrigin.y
        for line in chip.lines {
            Self.drawLine(ctx, line, at: CGPoint(x: chip.textOrigin.x, y: y))
            y += line.height
        }
        // The circle check: outlined to send, filled once a person message said it.
        ctx.saveGState()
        if chip.chosen {
            ctx.setFillColor(ink.cgColor)
            ctx.fillEllipse(in: chip.check)
        } else {
            ctx.setStrokeColor(ink.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: chip.check.insetBy(dx: 0.75, dy: 0.75))
        }
        ctx.restoreGState()
        Self.strokeCheck(ctx, in: chip.check.insetBy(dx: 5.5, dy: 6), color: chip.chosen ? Fixture.incoming : ink.withAlphaComponent(0.85), width: 1.8)
    }

    // MARK: Primitives (y down)

    static func drawLine(_ ctx: CGContext, _ line: HomeCardDraw.Line, at p: CGPoint) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: p.x, y: p.y + line.ascent)
        CTLineDraw(line.line, ctx)
        ctx.restoreGState()
    }

    static func fillRounded(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, _ color: UIColor) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// A check mark filling `rect` (its short stroke down-right, the long one up-right).
    static func strokeCheck(_ ctx: CGContext, in rect: CGRect, color: UIColor, width: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.midY))
        ctx.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A bitmap upright in the y-down context.
    static func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func drawCentered(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, scale: CGFloat) {
        let size = CGSize(width: CGFloat(image.width) / max(1, scale), height: CGFloat(image.height) / max(1, scale))
        drawImage(ctx, image, in: CGRect(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(),
                                         width: size.width, height: size.height))
    }
}

/// The cards' tile symbols, made once per symbol, colour and scale; owned by the card provider
/// (row bitmaps draw on their threads).
final class HomeChiefCardIcons: @unchecked Sendable {
    // Lock carve-out: a tiny synchronous cache read from drawing threads; no async caller.
    private let cache = OSAllocatedUnfairLock(initialState: [String: CGImage]())

    func image(_ name: String, size: CGFloat, color: NSColor, scale: CGFloat) -> CGImage? {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let key = "\(name)|\(size)|\(rgb.redComponent)|\(rgb.greenComponent)|\(rgb.blueComponent)|\(rgb.alphaComponent)|\(scale)"
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [rgb]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale))
        guard let cg = symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cache.withLock { if $0.count > 64 { $0.removeAll() }; $0[key] = cg }
        return cg
    }
}
