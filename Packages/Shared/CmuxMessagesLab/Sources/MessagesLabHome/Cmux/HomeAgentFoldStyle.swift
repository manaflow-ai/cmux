#if DEBUG
import AppKit
import CmuxHomeCore
import CoreGraphics
import CoreText

/// DEBUG ONLY: the agent-message header variants of the Agent Messages Playground (user 2026-11-02,
/// msg 19588: "give me more variations of agent messages ui"; msg 19613: "i want playground in swift,
/// not html"). Each case draws an agents row or a note of `HomeAgentFoldRowProvider` its own way, in
/// the real transcript; ``current`` is the shipped look. The playground registers a provider with a
/// style (`MessagesLabHomeView.debugSetAgentFoldStyle(_:)`); release builds always draw ``current``.
/// Titles and captions are DEV-only English.
public enum HomeAgentFoldStyle: Int, CaseIterable, Sendable {
    case current, avatarStack, centeredCaption, statusDots, latestPreview, tapbackBadge, leftRail, textOnly,
         hookUnder, capsuleButton, countBadge, senderLabel, divider, twoLine, progressBar, monoLog,
         // Spacing variants of the shipped line (user 2026-11-02, msg 19733): HomeAgentFoldSpacing.
         tight, airy, hugAbove, textAligned, deepIndent, wideChevronGap, snugChevron, roomyChips, compactChips,
         namesNoChips, smallCaption, minimal, airyAligned, balanced,
         // ChatGPT-style agent pills (user 2026-11-03, msg 19960): HomeAgentPills.
         pills, pillsTwoLine, pillChips

    /// A short name for the playground's picker.
    public var title: String {
        switch self {
        case .current: "Current (shipped)"
        case .avatarStack: "Avatar stack"
        case .centeredCaption: "Centered caption"
        case .statusDots: "Status dots"
        case .latestPreview: "Latest update preview"
        case .tapbackBadge: "Tapback-style badge"
        case .leftRail: "Left rail"
        case .textOnly: "Text only"
        case .hookUnder: "Hooked under the bubble"
        case .capsuleButton: "Outlined capsule"
        case .countBadge: "Count badge"
        case .senderLabel: "Sender label"
        case .divider: "Divider"
        case .twoLine: "Two lines with preview"
        case .progressBar: "Progress bar"
        case .monoLog: "Monospaced log"
        case .tight: "Spacing: tight (16 pt row)"
        case .airy: "Spacing: airy (10 pt above and below)"
        case .hugAbove: "Spacing: hugs the bubble above"
        case .textAligned: "Spacing: aligned with the bubble text"
        case .deepIndent: "Spacing: deep indent (28 pt)"
        case .wideChevronGap: "Spacing: wide chevron gap"
        case .snugChevron: "Spacing: snug chevron"
        case .roomyChips: "Spacing: roomy chips"
        case .compactChips: "Spacing: compact chips"
        case .namesNoChips: "Spacing: names, no chips"
        case .smallCaption: "Spacing: smaller caption type"
        case .minimal: "Spacing: minimal (tight, aligned, no chips)"
        case .airyAligned: "Spacing: airy and aligned"
        case .balanced: "Spacing: balanced (6 above, 4 below, aligned)"
        case .pills: "Pills: one per agent (ChatGPT)"
        case .pillsTwoLine: "Pills: two lines with status"
        case .pillChips: "Pills: compact chips in a row"
        }
    }

    /// What the variant does, one sentence, for the playground's caption.
    public var caption: String {
        switch self {
        case .current: "The shipped look: one pill per agent (an agents row); a note keeps the caption line."
        case .avatarStack: "Overlapping agent avatars (initials on a color from the agent's id), then the label."
        case .centeredCaption: "Centered like iMessage's \"Today 5:13 PM\": bold label, then the agents, no chevron."
        case .statusDots: "Each agent with a dot for its state: blue told, green reported, red stopped."
        case .latestPreview: "Chevron and label, then the newest message's first words."
        case .tapbackBadge: "A small badge hugging the bubble above, like a tapback: arrow and count."
        case .leftRail: "A thin rail at the left edge ties the line and its opened notes together."
        case .textOnly: "Plain muted text, \"Agent messages (3) · a959, a931\": no chevron, no chips."
        case .hookUnder: "Indented under the bubble's text with a ↳ hook, smaller."
        case .capsuleButton: "An outlined capsule button with the label and a chevron at its end."
        case .countBadge: "A filled accent circle with the count, then the agents as chips."
        case .senderLabel: "Like a group chat's sender name: \"Chief → a959, a931\" over the bubble's text."
        case .divider: "A centered label between two hairlines, like a section break."
        case .twoLine: "The shipped line, then the newest message's words on a second line."
        case .progressBar: "The label over a bar with a segment per agent, colored by its state."
        case .monoLog: "A monospaced log line: \"› 3 msgs  a959 a931\"."
        case .tight: "The shipped line in a 16 pt row: less gap to the bubbles above and below."
        case .airy: "The shipped line with 10 pt more room above and below it."
        case .hugAbove: "Close under the bubble it belongs to (16 pt line), 8 pt more room below."
        case .textAligned: "The chevron lines up with the bubble's text (12 pt in), not the bubble's edge."
        case .deepIndent: "The whole line 28 pt in from the bubbles' edge, like a reply."
        case .wideChevronGap: "12 pt between the chevron and the label, and between the label and the chips."
        case .snugChevron: "3 pt after the chevron, 4 pt before the chips: one tight group."
        case .roomyChips: "Taller chips (18 pt) with 9 pt padding and 8 pt between them."
        case .compactChips: "Small chips (14 pt) with 4 pt padding and 3 pt between them."
        case .namesNoChips: "The agents as plain text after a dot (\"· a915, a939\"): no chips."
        case .smallCaption: "An 11 pt label and 10 pt chips in an 18 pt row."
        case .minimal: "16 pt row, aligned with the bubble text, 11 pt type, the agents as text."
        case .airyAligned: "8 pt above and below, aligned with the bubble text, roomy chips."
        case .balanced: "6 pt above, 4 pt below, aligned with the bubble text, 11 pt label, compact chips."
        case .pills: "A pill per agent: status icon, task title, a blue dot for an unread report, ›. Click one to open its chat."
        case .pillsTwoLine: "Taller pills with a second line: Working, Reported or Stopped, and the agent's id."
        case .pillChips: "Small pills side by side in one row (the ones that do not fit are left out)."
        }
    }

    /// The style that draws `payload`, or nil for the shipped line (style 0, or a Feed row).
    static func drawing(_ payload: HomeAgentFoldRowProvider.Payload) -> HomeAgentFoldStyle? {
        guard payload.style != 0, payload.role != "feed" else { return nil }
        return HomeAgentFoldStyle(rawValue: payload.style)
    }

    /// The spacing of a spacing variant of the shipped line; nil for the other styles.
    var spacing: HomeAgentFoldSpacing? {
        var s = HomeAgentFoldSpacing.shipped
        let text = Fixture.bubblePadX
        switch self {
        case .tight: s.line = 16
        case .airy: (s.above, s.below) = (10, 10)
        case .hugAbove: (s.line, s.below) = (16, 8)
        case .textAligned: s.indent = text
        case .deepIndent: s.indent = 28
        case .wideChevronGap: (s.chevronGap, s.labelGap) = (12, 12)
        case .snugChevron: (s.chevronGap, s.labelGap) = (3, 4)
        case .roomyChips: (s.chipHeight, s.chipPad, s.chipGap) = (18, 9, 8)
        case .compactChips: (s.chipHeight, s.chipPad, s.chipGap) = (14, 4, 3)
        case .namesNoChips: s.chips = false
        case .smallCaption: (s.line, s.labelSize, s.chipSize, s.chipHeight, s.chipPad) = (18, 11, 10, 14, 5)
        case .minimal: (s.line, s.indent, s.labelSize, s.chipSize, s.chips) = (16, text, 11, 11, false)
        case .airyAligned: (s.above, s.below, s.indent, s.chipHeight, s.chipPad, s.chipGap) = (8, 8, text, 18, 9, 8)
        case .balanced: (s.above, s.below, s.indent, s.labelSize, s.chipHeight, s.chipPad, s.chipGap) = (6, 4, text, 11, 14, 4, 3)
        default: return nil
        }
        return s
    }

    /// True for the pill styles (one pill per agent; a click on a pill opens that agent).
    public var isPill: Bool { pillShape != nil }

    /// The pill shape of a pill style; nil for the other styles.
    var pillShape: HomeAgentPills.Shape? {
        switch self {
        case .pills: .pill
        case .pillsTwoLine: .twoLine
        case .pillChips: .chip
        default: nil
        }
    }

    /// The row's height in this style.
    func height(_ p: HomeAgentFoldRowProvider.Payload) -> CGFloat {
        if let spacing { return spacing.height }
        if let pillShape, p.role != "note" { return HomeAgentPills(p, shape: pillShape, width: .greatestFiniteMagnitude).height }
        if self == .current, HomeAgentFoldRowProvider.drawsPills(p) { return HomeAgentPills(p, shape: .pill, width: .greatestFiniteMagnitude).height }
        guard p.role != "note" else { return HomeAgentFoldRowProvider.height }
        switch self {
        case .twoLine: return p.open || p.latest == nil ? HomeAgentFoldRowProvider.height : 38
        case .progressBar: return p.open ? HomeAgentFoldRowProvider.height : 32
        case .avatarStack, .tapbackBadge, .countBadge, .capsuleButton: return 26
        default: return HomeAgentFoldRowProvider.height
        }
    }

    /// Draws `p` in `rect` (the row; top-left origin, y down).
    func draw(_ p: HomeAgentFoldRowProvider.Payload, in ctx: CGContext, rect: CGRect) {
        if let spacing { spacing.draw(p, in: ctx, rect: rect); return }
        if let pillShape, p.role != "note" { HomeAgentPills(p, shape: pillShape, width: rect.width).draw(ctx, origin: rect.origin); return }
        let mid = rect.minY + height(p) / 2
        let x0 = rect.minX
        if p.role == "note" { drawNote(p, ctx, x0: x0, mid: mid, width: rect.width); return }
        let muted = Fixture.secondaryText
        let label = ink(p.label, 12, .medium, muted)
        let peersText = HomeAgentMessageRow.peerPreview(p.peers, separator: ", ")
        switch self {
        case .current:
            if HomeAgentFoldRowProvider.drawsPills(p) {
                HomeAgentPills(p, shape: .pill, width: rect.width).draw(ctx, origin: rect.origin)
            } else {
                HomeAgentFoldLine(p, width: rect.width).draw(ctx, at: rect.origin)
            }
        case .avatarStack:
            var x = x0 + 10
            if !p.open {
                for peer in p.peers.prefix(4) {
                    avatar(ctx, peer, center: CGPoint(x: x, y: mid), radius: 10)
                    x += 14
                }
                x += 10
            } else {
                chevron(ctx, center: CGPoint(x: x0 + 5, y: mid), open: true)
                x = x0 + 16
            }
            _ = line(ctx, label, x: x, mid: mid)
        case .centeredCaption:
            let text = NSMutableAttributedString(attributedString: ink(p.label, 11, .semibold, muted))
            if !p.open, !peersText.isEmpty { text.append(ink("  " + peersText, 11, .regular, muted)) }
            _ = line(ctx, text, x: rect.midX - HomeTableGrid.lineWidth(text) / 2, mid: mid)
        case .statusDots:
            chevron(ctx, center: CGPoint(x: x0 + 5, y: mid), open: p.open)
            var x = x0 + 16 + line(ctx, label, x: x0 + 16, mid: mid) + 10
            guard !p.open else { return }
            for (peer, state) in zip(p.peers, p.states) where x < rect.maxX - 40 {
                circle(ctx, CGPoint(x: x + 3, y: mid), 3.5, stateColor(state))
                x += 10 + line(ctx, ink(peer, 11, .regular, muted), x: x + 10, mid: mid) + 10
            }
        case .latestPreview:
            chevron(ctx, center: CGPoint(x: x0 + 5, y: mid), open: p.open)
            let x = x0 + 16 + line(ctx, label, x: x0 + 16, mid: mid)
            if !p.open, let latest = p.latest {
                truncated(ctx, ink(" — " + firstLine(latest), 12, .regular, muted.withAlphaComponent(0.8)), x: x, mid: mid,
                          width: rect.maxX - x - 8)
            }
        case .tapbackBadge:
            let text = ink(p.open ? "▾ " + p.label : "↗ \(p.count)", 12, .semibold, Fixture.incomingText)
            let w = HomeTableGrid.lineWidth(text) + 16
            let badge = CGRect(x: x0 + 8, y: rect.minY + 1, width: w, height: 22)
            capsule(ctx, badge, fill: Fixture.incoming, stroke: muted.withAlphaComponent(0.35))
            _ = line(ctx, text, x: badge.minX + 8, mid: badge.midY)
            if !p.open { _ = line(ctx, ink(peersText, 11, .regular, muted), x: badge.maxX + 8, mid: badge.midY) }
        case .leftRail:
            rail(ctx, x: x0 + 3, top: rect.minY + 3, bottom: rect.maxY - (p.open ? 0 : 3))
            let x = x0 + 14 + line(ctx, label, x: x0 + 14, mid: mid)
            if !p.open, !peersText.isEmpty { _ = line(ctx, ink(" · " + peersText, 12, .regular, muted), x: x, mid: mid) }
        case .textOnly:
            let text = p.open || peersText.isEmpty ? p.label : "\(p.label) · \(peersText)"
            _ = line(ctx, ink(text, 12, .regular, muted), x: x0, mid: mid)
        case .hookUnder:
            let x = x0 + Fixture.bubblePadX
            let w = line(ctx, ink("↳", 12, .regular, muted), x: x, mid: mid)
            let text = p.open || peersText.isEmpty ? p.label : "\(p.label) · \(peersText)"
            _ = line(ctx, ink(text, 11, .regular, muted), x: x + w + 4, mid: mid)
        case .capsuleButton:
            let text = ink(p.label + (p.open ? "  ⌃" : "  ›"), 12, .medium, muted)
            let w = HomeTableGrid.lineWidth(text) + 20
            let pill = CGRect(x: x0, y: mid - 11, width: w, height: 22)
            capsule(ctx, pill, fill: nil, stroke: muted.withAlphaComponent(0.5))
            _ = line(ctx, text, x: pill.minX + 10, mid: mid)
        case .countBadge:
            circle(ctx, CGPoint(x: x0 + 11, y: mid), 11, NSColor.controlAccentColor)
            let count = ink(p.open ? "−" : "\(p.count)", 12, .bold, .white)
            _ = line(ctx, count, x: x0 + 11 - HomeTableGrid.lineWidth(count) / 2, mid: mid)
            if p.open {
                _ = line(ctx, label, x: x0 + 30, mid: mid)
            } else {
                chips(ctx, p.peers, x: x0 + 30, mid: mid, maxX: rect.maxX - 8)
            }
        case .senderLabel:
            let text = p.open ? p.label : "Chief → \(peersText) · \(p.count)"
            _ = line(ctx, ink(text, 11, .regular, muted), x: x0 + Fixture.bubblePadX, mid: mid)
        case .divider:
            let text = ink(p.label, 11, .medium, muted)
            let w = HomeTableGrid.lineWidth(text)
            let start = rect.midX - w / 2
            HomeCardDraw.hairline(ctx, from: CGPoint(x: x0, y: mid), to: CGPoint(x: start - 10, y: mid), strong: false)
            HomeCardDraw.hairline(ctx, from: CGPoint(x: start + w + 10, y: mid), to: CGPoint(x: rect.maxX, y: mid), strong: false)
            _ = line(ctx, text, x: start, mid: mid)
        case .twoLine:
            let top = rect.minY + HomeAgentFoldRowProvider.height / 2
            HomeAgentFoldLine(p, width: rect.width).draw(ctx, at: rect.origin)
            if !p.open, let latest = p.latest {
                truncated(ctx, ink(firstLine(latest), 11, .regular, muted.withAlphaComponent(0.8)), x: x0 + 16, mid: top + 15,
                          width: rect.width - 24)
            }
        case .progressBar:
            guard !p.open else {
                chevron(ctx, center: CGPoint(x: x0 + 5, y: mid), open: true)
                _ = line(ctx, label, x: x0 + 16, mid: mid)
                return
            }
            _ = line(ctx, ink(p.label, 11, .medium, muted), x: x0, mid: rect.minY + 10)
            let bar = CGRect(x: x0, y: rect.minY + 21, width: min(260, rect.width - 8), height: 5)
            segments(ctx, bar, p.states)
        case .monoLog:
            let text = p.open ? "⌄ hide \(p.count)" : "› \(p.count) msgs  " + p.peers.prefix(4).joined(separator: " ")
            _ = line(ctx, NSAttributedString(string: text, attributes: [.font: HomeFonts.monospaced(ofSize: 11), .foregroundColor: muted]),
                     x: x0, mid: mid)
        default:
            // The spacing variants drew above (``spacing``).
            break
        }
    }

    /// An opened note's line ("a931 · stopped without a report …") in this style.
    private func drawNote(_ p: HomeAgentFoldRowProvider.Payload, _ ctx: CGContext, x0: CGFloat, mid: CGFloat, width: CGFloat) {
        let muted = Fixture.secondaryText
        let text = ink(p.label, 12, .regular, muted)
        switch self {
        case .statusDots:
            circle(ctx, CGPoint(x: x0 + 19, y: mid), 3.5, stateColor("stopped"))
            _ = line(ctx, text, x: x0 + 28, mid: mid)
        case .avatarStack:
            avatar(ctx, p.peers.first ?? "", center: CGPoint(x: x0 + 24, y: mid), radius: 8)
            _ = line(ctx, text, x: x0 + 38, mid: mid)
        case .leftRail:
            rail(ctx, x: x0 + 3, top: mid - HomeAgentFoldRowProvider.height / 2, bottom: mid + HomeAgentFoldRowProvider.height / 2)
            _ = line(ctx, text, x: x0 + 14, mid: mid)
        case .monoLog:
            _ = line(ctx, NSAttributedString(string: "  " + p.label, attributes: [.font: HomeFonts.monospaced(ofSize: 11), .foregroundColor: muted]),
                     x: x0, mid: mid)
        case .centeredCaption, .divider:
            let small = ink(p.label, 11, .regular, muted)
            _ = line(ctx, small, x: x0 + width / 2 - HomeTableGrid.lineWidth(small) / 2, mid: mid)
        case .hookUnder, .senderLabel:
            _ = line(ctx, ink(p.label, 11, .regular, muted), x: x0 + Fixture.bubblePadX + 14, mid: mid)
        default:
            _ = line(ctx, text, x: x0 + HomeAgentFoldRowProvider.chevronWidth + HomeAgentFoldRowProvider.gap, mid: mid)
        }
    }
}

// MARK: Drawing helpers (pure CoreGraphics and CoreText, any thread)

private func ink(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: HomeFonts.system(ofSize: size, weight: weight), .foregroundColor: color])
}

/// `text` on one line centered on `mid` (y down) at `x`; its width.
private func line(_ ctx: CGContext, _ text: NSAttributedString, x: CGFloat, mid: CGFloat) -> CGFloat {
    draw(ctx, CTLineCreateWithAttributedString(text), x: x, mid: mid)
}

/// `text` cut with "…" to `width`.
private func truncated(_ ctx: CGContext, _ text: NSAttributedString, x: CGFloat, mid: CGFloat, width: CGFloat) {
    guard width > 12, text.length > 0 else { return }
    let full = CTLineCreateWithAttributedString(text)
    let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil)))
    _ = draw(ctx, CTLineCreateTruncatedLine(full, Double(width), .end, token) ?? full, x: x, mid: mid)
}

private func draw(_ ctx: CGContext, _ ctLine: CTLine, x: CGFloat, mid: CGFloat) -> CGFloat {
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: mid + (ascent - descent) / 2)
    CTLineDraw(ctLine, ctx)
    ctx.restoreGState()
    return width.rounded(.up)
}

/// The first line of `text` as plain words: a Markdown link shows its text, emphasis marks go.
private func firstLine(_ text: String) -> String {
    let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    let linked = first.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    return linked.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
}

private func circle(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ color: NSColor) {
    ctx.saveGState()
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    ctx.restoreGState()
}

/// An agent's avatar: a disc in a color from its id, with its id's last two characters.
private func avatar(_ ctx: CGContext, _ peer: String, center: CGPoint, radius: CGFloat) {
    let zero: UInt8 = 0
    let hue = CGFloat(peer.utf8.reduce(zero) { $0 &* 31 &+ $1 }) / 255
    circle(ctx, center, radius + 1.5, Fixture.incoming)
    circle(ctx, center, radius, NSColor(calibratedHue: hue, saturation: 0.45, brightness: 0.78, alpha: 1))
    let initials = NSAttributedString(string: String(peer.suffix(2)),
                                      attributes: [.font: HomeFonts.system(ofSize: radius * 0.9, weight: .semibold), .foregroundColor: NSColor.white])
    _ = line(ctx, initials, x: center.x - HomeTableGrid.lineWidth(initials) / 2, mid: center.y)
}

private func chevron(_ ctx: CGContext, center c: CGPoint, open: Bool) {
    ctx.saveGState()
    ctx.setStrokeColor(Fixture.secondaryText.cgColor)
    ctx.setLineWidth(1.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    if open {
        ctx.move(to: CGPoint(x: c.x - 3.5, y: c.y - 1.75))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + 1.75))
        ctx.addLine(to: CGPoint(x: c.x + 3.5, y: c.y - 1.75))
    } else {
        ctx.move(to: CGPoint(x: c.x - 1.75, y: c.y - 3.5))
        ctx.addLine(to: CGPoint(x: c.x + 1.75, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x - 1.75, y: c.y + 3.5))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

private func capsule(_ ctx: CGContext, _ rect: CGRect, fill: NSColor?, stroke: NSColor) {
    let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
    ctx.saveGState()
    if let fill {
        ctx.addPath(path)
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
    }
    ctx.addPath(path)
    ctx.setStrokeColor(stroke.cgColor)
    ctx.setLineWidth(1)
    ctx.strokePath()
    ctx.restoreGState()
}

private func rail(_ ctx: CGContext, x: CGFloat, top: CGFloat, bottom: CGFloat) {
    ctx.saveGState()
    ctx.setStrokeColor(Fixture.secondaryText.withAlphaComponent(0.45).cgColor)
    ctx.setLineWidth(2)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: x, y: top))
    ctx.addLine(to: CGPoint(x: x, y: bottom))
    ctx.strokePath()
    ctx.restoreGState()
}

/// `peers` as gray chips from `start`, as many as fit before `maxX`, then "+N" for the rest.
private func chips(_ ctx: CGContext, _ peers: [String], x start: CGFloat, mid: CGFloat, maxX: CGFloat) {
    let muted = Fixture.secondaryText
    var x = start
    for (shown, peer) in peers.enumerated() {
        let text = ink(peer, 11, .regular, muted)
        let w = HomeTableGrid.lineWidth(text) + 12
        guard x + w + 24 < maxX else {
            _ = line(ctx, ink("+\(peers.count - shown)", 11, .regular, muted), x: x, mid: mid)
            return
        }
        capsule(ctx, CGRect(x: x, y: mid - 8, width: w, height: 16), fill: muted.withAlphaComponent(0.14), stroke: .clear)
        _ = line(ctx, text, x: x + 6, mid: mid)
        x += w + 4
    }
}

/// One segment per agent, colored by its state, across `bar`.
private func segments(_ ctx: CGContext, _ bar: CGRect, _ states: [String]) {
    guard !states.isEmpty else { return }
    let gap: CGFloat = 2
    let width = (bar.width - gap * CGFloat(states.count - 1)) / CGFloat(states.count)
    var x = bar.minX
    for state in states {
        let segment = CGRect(x: x, y: bar.minY, width: max(1, width), height: bar.height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: segment, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
        ctx.setFillColor(stateColor(state).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        x += width + gap
    }
}

private func stateColor(_ state: String) -> NSColor {
    switch state {
    case "reported": NSColor.systemGreen
    case "stopped": NSColor.systemRed
    default: NSColor.systemBlue
    }
}
#endif
