import AppKit

// Accessibility and text selection for the transcript. The rows are the
// shared layer tree (outside the scroll view's document view), so both are
// explicit: the document view is an accessibility list with one element per
// visible message, and a drag selects text across rows (Copy puts it on the
// pasteboard).

// MARK: Accessibility

/// One message: role, sender, text and time.
final class MessageAccessibilityElement: NSAccessibilityElement {
    let messageID: ID
    init(messageID: ID) { self.messageID = messageID; super.init() }
}

extension NativeStrings {
    static var messagesList: String { String(localized: "ax.messages", defaultValue: "Messages", table: "AppKitNative") }
    static var messageRole: String { String(localized: "ax.message.role", defaultValue: "message", table: "AppKitNative") }
    /// "Attachment: %@"
    static var attachmentFormat: String { String(localized: "ax.attachment", defaultValue: "Attachment: %@", table: "AppKitNative") }
    static var you: String { String(localized: "ax.you", defaultValue: "You", table: "AppKitNative") }
    /// sender, text, time
    static var messageFormat: String { String(localized: "ax.message.format", defaultValue: "%1$@, %2$@, %3$@", table: "AppKitNative") }
}

extension ChatController {
    /// The visible messages: id, the union of their part bodies (window
    /// content coordinates) and their text, top to bottom.
    func visibleMessages() -> [(id: ID, frame: CGRect, text: String)] {
        guard let demo else { return [] }
        var order: [ID] = []
        var by: [ID: (CGRect, [(Int, String)])] = [:]
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, case let .part(p) = spec.kind else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: demo)
            guard body.maxY > Fixture.headerHeight, body.minY < demo.anchorY + 20 else { continue }
            let id = p.ref.messageId
            let t = p.text?.text ?? Self.describe(p.part)
            if let e = by[id] { by[id] = (e.0.union(body), e.1 + [(p.ref.partIndex, t)]) } else { by[id] = (body, [(p.ref.partIndex, t)]); order.append(id) }
        }
        return order.compactMap { id in
            guard let (f, parts) = by[id] else { return nil }
            return (id, f, parts.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.isEmpty }.joined(separator: "\n"))
        }.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// Spoken text of a part without a text layout.
    static func describe(_ part: Part) -> String {
        switch part {
        case let .text(t, _): return t
        case let .link(url, title, site, _, _): return [title, site ?? url].compactMap { $0 }.joined(separator: ", ")
        case let .attachment(a): return String(format: NativeStrings.attachmentFormat, a.fileName)
        case let .location(_, _, title, subtitle): return [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        }
    }

    func accessibilityElements(parent: NSView) -> [NSAccessibilityElement] {
        guard let store, let window = host.window else { return [] }
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        return visibleMessages().map { m in
            let e = MessageAccessibilityElement(messageID: m.id)
            let msg = store.state.message(m.id)
            let sender = msg.map { msg in
                msg.senderId == store.state.me ? NativeStrings.you
                    : store.state.conversation.participants.first { $0.id == msg.senderId }?.displayName ?? msg.senderId
            } ?? ""
            let when = msg.map { time.string(from: Instant.parse($0.sentAt)) } ?? ""
            e.setAccessibilityRole(.staticText)
            e.setAccessibilityRoleDescription(NativeStrings.messageRole)
            e.setAccessibilityLabel(String(format: NativeStrings.messageFormat, sender, m.text, when))
            e.setAccessibilityValue(m.text)
            e.setAccessibilityTitle(sender)
            e.setAccessibilityParent(parent)
            let inWindow = host.convert(m.frame, to: nil)
            e.setAccessibilityFrame(window.convertToScreen(inWindow))
            return e
        }
    }
}

extension TranscriptDocumentView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { NativeStrings.messagesList }
    override func accessibilityChildren() -> [Any]? { controller?.accessibilityElements(parent: self) }
    override func accessibilityVisibleChildren() -> [Any]? { accessibilityChildren() }
}

// MARK: Selection

/// A text position in the transcript: a row (by key) and a UTF-16 offset.
struct TextPosition: Equatable { var key: String; var offset: Int }

/// Drag-to-select across rows. The highlight is a shape layer over the rows,
/// recomputed when the transcript moves or changes.
final class TranscriptSelection {
    unowned let controller: ChatController
    let layer = CAShapeLayer()
    private(set) var anchor: TextPosition?
    private(set) var focus: TextPosition?
    private var downPoint: CGPoint?
    private(set) var dragging = false

    init(controller: ChatController) {
        self.controller = controller
        layer.fillColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55).cgColor
        layer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.compositingFilter = "screenBlendMode"
    }

    var isEmpty: Bool { anchor == nil || anchor == focus }

    func mouseDown(_ p: CGPoint) {
        downPoint = p
        dragging = false
        clear()
    }

    /// Returns true when the drag selects (it is not a click).
    @discardableResult
    func mouseDragged(_ p: CGPoint) -> Bool {
        guard let d = downPoint else { return false }
        if !dragging {
            guard hypot(p.x - d.x, p.y - d.y) > 3, let a = position(at: d) else { return false }
            dragging = true
            anchor = a
        }
        if let f = position(at: p) { focus = f }
        refresh()
        return true
    }

    func mouseUp() -> Bool {
        defer { downPoint = nil; dragging = false }
        return dragging
    }

    func clear() {
        anchor = nil; focus = nil
        refresh()
    }

    /// Rows with text, in transcript order (model index).
    private func textRows() -> [(index: Int, key: String, row: PartRow, body: CGRect)] {
        guard let demo = controller.demo else { return [] }
        var out: [(Int, String, PartRow, CGRect)] = []
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, case let .part(p) = spec.kind, p.text != nil, let i = demo.model.index[spec.key] else { continue }
            out.append((i, spec.key, p, cell.convert(RowDraw.bodyRect(spec), to: demo)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// The text position nearest to a point (window content coordinates).
    func position(at p: CGPoint) -> TextPosition? {
        let rows = textRows()
        guard !rows.isEmpty else { return nil }
        // The row under the point, else the nearest by vertical distance.
        let r = rows.min { a, b in
            let da = p.y < a.body.minY ? a.body.minY - p.y : max(0, p.y - a.body.maxY)
            let db = p.y < b.body.minY ? b.body.minY - p.y : max(0, p.y - b.body.maxY)
            return da < db
        }!
        guard let tl = r.row.text else { return nil }
        if p.y < r.body.minY { return TextPosition(key: r.key, offset: 0) }
        if p.y > r.body.maxY { return TextPosition(key: r.key, offset: (tl.text as NSString).length) }
        let x = p.x - r.body.minX - Fixture.bubblePadX, y = p.y - r.body.minY - Fixture.bubblePadY
        let i = min(tl.lines.count - 1, max(0, Int(floor(y / Fixture.lineHeight))))
        let line = ctLine(tl, i)
        let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: max(0, x), y: 0))
        let off = idx == kCFNotFound ? tl.lines[i].range.location : tl.lines[i].range.location + idx
        return TextPosition(key: r.key, offset: min(off, NSMaxRange(tl.lines[i].range)))
    }

    private func ctLine(_ tl: TextLayout, _ i: Int) -> CTLine {
        let attr = tl.attributed(color: .white, linkColor: .white)
        return CTLineCreateWithAttributedString(attr.attributedSubstring(from: tl.lines[i].range))
    }

    /// Selected (row key, range) pairs in order, over the loaded rows.
    func selectedRanges() -> [(key: String, range: NSRange, text: String)] {
        guard let demo = controller.demo, let a = anchor, let f = focus, a != f,
              let ia = demo.model.index[a.key], let fi = demo.model.index[f.key] else { return [] }
        let (s, e) = (ia, a.offset) <= (fi, f.offset) ? (a, f) : (f, a)
        let lo = min(ia, fi), hi = max(ia, fi)
        var out: [(String, NSRange, String)] = []
        for i in lo...hi {
            guard case let .part(p) = demo.model.rows[i].spec.kind, let tl = p.text else { continue }
            let key = demo.model.rows[i].spec.key
            let len = (tl.text as NSString).length
            let from = key == s.key ? s.offset : 0
            let to = key == e.key ? e.offset : len
            guard to > from else { continue }
            let r = NSRange(location: from, length: to - from)
            out.append((key, r, (tl.text as NSString).substring(with: r)))
        }
        return out
    }

    var selectedText: String { selectedRanges().map(\.text).joined(separator: "\n") }

    /// Rebuild the highlight for the rows on screen.
    func refresh() {
        let path = CGMutablePath()
        let ranges = Dictionary(selectedRanges().map { ($0.key, $0.range) }, uniquingKeysWith: { a, _ in a })
        if !ranges.isEmpty {
            for r in textRows() {
                guard let sel = ranges[r.key], let tl = r.row.text else { continue }
                for (i, line) in tl.lines.enumerated() {
                    let inter = NSIntersectionRange(sel, line.range)
                    let empty = line.range.length == 0 && NSLocationInRange(line.range.location, sel)
                    guard inter.length > 0 || empty else { continue }
                    let ct = ctLine(tl, i)
                    let x0 = CTLineGetOffsetForStringIndex(ct, inter.location - line.range.location, nil)
                    let x1 = inter.length > 0 ? CTLineGetOffsetForStringIndex(ct, NSMaxRange(inter) - line.range.location, nil) : x0 + 4
                    path.addRect(CGRect(x: r.body.minX + Fixture.bubblePadX + x0, y: r.body.minY + Fixture.bubblePadY + CGFloat(i) * Fixture.lineHeight,
                                        width: max(2, x1 - x0), height: Fixture.lineHeight))
                }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.path = path.isEmpty ? nil : path
        CATransaction.commit()
    }
}

extension TranscriptDocumentView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) {
        guard let text = controller?.selection.selectedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return controller?.selection.isEmpty == false }
        return false
    }
}
