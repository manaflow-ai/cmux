import AppKit

/// cmux: a message's links as accessibility links (goal agent-shortcut-found: the onboarding walk and
/// VoiceOver find Chief's welcome link "turn it on" and press it). The bubbles are drawn layers, so each
/// link is an explicit `NSAccessibilityElement` child of its message's element
/// (`MessageAccessibilityElement`, TranscriptAccess.swift): role link, the shown text as its label, its
/// rect on screen, and a press that opens it the way a click does (`ChatController.openLink`).
struct TranscriptLink: Equatable {
    /// The link's shown text ("turn it on").
    var label: String
    /// What a click on it opens (`ChatController.linkTarget`'s answer for a point on it).
    var target: PaneLinkTarget
    /// One rect per line the link is on, body-local (origin the bubble's top-left, padding included).
    var rects: [CGRect]
    /// All of its lines.
    var frame: CGRect { rects.dropFirst().reduce(rects.first ?? .null) { $0.union($1) } }
}

extension PartRow {
    /// This row's links in reading order, from the geometry a click hit-tests (`ChatController.linkTarget`):
    /// a Markdown row's MarkdownLayout, a text row's TextLayout, else a link card as one link over its body.
    func accessibilityLinks(bodySize: CGSize) -> [TranscriptLink] {
        if let markdown { return markdown.accessibilityLinks }
        if let text, case let links = text.accessibilityLinks(origin: CGPoint(x: Fixture.bubblePadX, y: Fixture.bubblePadY)), !links.isEmpty {
            return links
        }
        if case let .link(url, title, site, _, _) = part {
            return [TranscriptLink(label: title ?? site ?? url, target: .card(url, MarkdownLinkPolicy.url(url)),
                                   rects: [CGRect(origin: .zero, size: bodySize)])]
        }
        return []
    }
}

/// Link pieces in reading order, joined into links: a piece continues the previous link when it has the
/// same destination and starts where that one ended (a link wrapped onto the next line).
private struct TranscriptLinkPieces {
    private(set) var links: [TranscriptLink] = []
    private var ends: [Int] = []

    mutating func add(dest: String, text: String, start: Int, end: Int, rect: CGRect) {
        if case let .text(url)? = links.last?.target, url == MarkdownLinkPolicy.url(dest),
           let last = ends.last, start >= last, start - last <= 1, var link = links.popLast() {
            ends.removeLast()
            link.label += (start > last && !link.label.hasSuffix(" ") ? " " : "") + text
            link.rects.append(rect)
            links.append(link)
        } else {
            links.append(TranscriptLink(label: text, target: .text(MarkdownLinkPolicy.url(dest)), rects: [rect]))
        }
        ends.append(end)
    }

    /// The links, labels without the edge spaces a wrap or a chip's pad leaves.
    var finished: [TranscriptLink] {
        links.compactMap { link in
            var link = link
            link.label = link.label.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}")))
            return link.label.isEmpty ? nil : link
        }
    }
}

extension TextLayout {
    /// The links of a text row; `origin` is the text's first line top in body coordinates. A line is
    /// `Fixture.lineHeight` tall, as `link(at:)` hit-tests it.
    func accessibilityLinks(origin: CGPoint) -> [TranscriptLink] {
        guard runs.contains(where: { $0.link != nil }) else { return [] }
        let attr = attributed(color: .white, linkColor: .white)
        let ns = attr.string as NSString
        var pieces = TranscriptLinkPieces()
        for (i, l) in lines.enumerated() {
            let range = l.range
            // lines measured for another text (stale during an edit or a streamed reply) are not read past the end.
            guard range.length > 0, Self.range(range.location, range.length, in: attr.length) != nil else { continue }
            let line = CTLineCreateWithAttributedString(attr.attributedSubstring(from: range))
            let y = origin.y + CGFloat(i) * Fixture.lineHeight
            for r in runs {
                guard let dest = r.link else { continue }
                let lo = max(r.start, range.location), hi = min(r.start &+ r.length, NSMaxRange(range))
                guard hi > lo else { continue }
                let x0 = CTLineGetOffsetForStringIndex(line, lo - range.location, nil)
                let x1 = CTLineGetOffsetForStringIndex(line, hi - range.location, nil)
                let rect = CGRect(x: origin.x + x0, y: y, width: max(1, x1 - x0), height: Fixture.lineHeight)
                pieces.add(dest: dest, text: ns.substring(with: NSRange(location: lo, length: hi - lo)), start: lo, end: hi, rect: rect)
            }
        }
        return pieces.finished
    }
}

extension MarkdownLayout {
    /// The links of a Markdown row, body-local; a piece scrolled out of its region (a wide table or code
    /// block) is left out, as `link(at:)` does not hit it.
    var accessibilityLinks: [TranscriptLink] {
        var pieces = TranscriptLinkPieces()
        for f in frags where !f.links.isEmpty {
            let shown = visibleRect(f)
            let dx = f.region < 0 ? 0 : MarkdownScroll.offset(identity: identity, region: f.region)
            let s = f.attr.string as NSString
            for (r, dest) in f.links {
                guard r.length > 0, NSMaxRange(r) <= s.length else { continue }
                let x0 = CTLineGetOffsetForStringIndex(f.line, r.location, nil)
                let x1 = CTLineGetOffsetForStringIndex(f.line, NSMaxRange(r), nil)
                let rect = CGRect(x: f.origin.x - dx + x0, y: f.origin.y, width: max(1, x1 - x0), height: f.height).intersection(shown)
                guard !rect.isNull, !rect.isEmpty else { continue }
                pieces.add(dest: dest, text: s.substring(with: r), start: f.range.location + r.location,
                           end: f.range.location + NSMaxRange(r), rect: rect)
            }
        }
        return pieces.finished
    }
}

/// cmux: one link of a transcript message for accessibility: a press opens it as a click does.
final class TranscriptLinkElement: NSAccessibilityElement {
    weak var controller: ChatController?
    var target: PaneLinkTarget = .text(nil)
    var ref = PartRef(messageId: "", partIndex: 0)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { controller?.openLink(target, ref: ref) ?? false }
}

extension ChatController {
    /// The visible rows of each message and their bodies (demo coordinates), part order: the rows
    /// `visibleMessages()` reads, without a streaming bubble's (it takes no click).
    func accessibilityLinkRows() -> [ID: [(row: PartRow, body: CGRect)]] {
        guard let demo else { return [:] }
        var by: [ID: [(row: PartRow, body: CGRect)]] = [:]
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, case let .part(p) = spec.kind, !StreamBubble.isStream(p.ref.messageId) else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: demo)
            guard body.maxY > demo.visibleTop, body.minY < demo.anchorY + 20 else { continue }
            by[p.ref.messageId, default: []].append((p, body))
        }
        return by.mapValues { $0.sorted { $0.row.ref.partIndex < $1.row.ref.partIndex } }
    }

    /// The link elements of `message` (its visible links), kept on it by link index and reused: AX
    /// clients hold them between calls, as they hold the message elements (TranscriptSelection.axElements).
    func accessibilityLinkElements(_ rows: [(row: PartRow, body: CGRect)], of message: MessageAccessibilityElement,
                                   window: NSWindow) -> [NSAccessibilityElement] {
        guard let demo else { message.cmuxLinks = [:]; return [] }
        var kept: [Int: TranscriptLinkElement] = [:]
        var out: [NSAccessibilityElement] = []
        var index = 0
        for (row, body) in rows {
            for link in row.accessibilityLinks(bodySize: body.size) {
                defer { index += 1 }
                let shown = link.frame.offsetBy(dx: body.minX, dy: body.minY)
                guard shown.maxY > demo.visibleTop, shown.minY < demo.anchorY + 20 else { continue }
                let e = message.cmuxLinks[index] ?? TranscriptLinkElement()
                kept[index] = e
                e.controller = self
                e.target = link.target
                e.ref = row.ref
                e.setAccessibilityRole(.link)
                e.setAccessibilityLabel(link.label)
                switch link.target {
                case let .text(url), let .card(_, url): e.setAccessibilityURL(url)
                }
                e.setAccessibilityParent(message)
                e.setAccessibilityFrame(window.convertToScreen(host.convert(shown, to: nil)))
                out.append(e)
            }
        }
        message.cmuxLinks = kept
        return out
    }
}
