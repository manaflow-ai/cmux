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
    static var messagesList: String { String(localized: "ax.messages", defaultValue: "Messages", table: "AppKitNative", bundle: .module) }
    static var messageRole: String { String(localized: "ax.message.role", defaultValue: "message", table: "AppKitNative", bundle: .module) }
    /// "Attachment: %@"
    static var attachmentFormat: String { String(localized: "ax.attachment", defaultValue: "Attachment: %@", table: "AppKitNative", bundle: .module) }
    static var you: String { String(localized: "ax.you", defaultValue: "You", table: "AppKitNative", bundle: .module) }
    /// sender, text, time
    static var messageFormat: String { String(localized: "ax.message.format", defaultValue: "%1$@, %2$@, %3$@", table: "AppKitNative", bundle: .module) }
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
        case let .custom(c): return CustomRows.plainText(c)  // cmux: d5d6a18's custom parts (this file stays at bd65bbf)
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
        // Screen blend of P3 (2.6, 37.7, 85): over the incoming bubble (59, 59, 61) it gives
        // Messages' highlight (61, 88, 126) and over its text (225) the selected text
        // (225, 229, 235) (lossless still selected-text.png).
        layer.fillColor = Fixture.p3(2.6, 37.7, 85).cgColor
        layer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.compositingFilter = "screenBlendMode"
    }

    var isEmpty: Bool { anchor == nil || anchor == focus }

    // MARK: Selected message (a click on a bubble)

    /// Real Messages (macOS 27, click-incoming / click-outgoing / click-empty references): a
    /// click on a bubble selects that message. Its bubble brightens (incoming 59 -> 98, white
    /// at 20 %) or darkens (outgoing (72,147,247) -> (45,89,192), multiply), easing in over
    /// 0.22 s from about 30 ms after the release (ours starts at the release: faster than
    /// Messages is the rule, the evidence aligns on the first response); a click elsewhere (another bubble, the empty
    /// transcript) or the second press of a double-click takes it off: ease-out 0.2 s.
    /// The layer follows the row (refresh() runs on every scroll and layout).
    let bubbleLayer = CAShapeLayer()
    private(set) var selectedKey: String?
    static let bubbleOnDelay: CFTimeInterval = 0, bubbleOnDuration: CFTimeInterval = 0.22
    static let bubbleOffDuration: CFTimeInterval = 0.2

    func selectBubble(_ key: String, outgoing: Bool) {
        if selectedKey == key { return }
        if selectedKey != nil { deselectBubble() }
        selectedKey = key
        let l = CAShapeLayer()
        l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        if outgoing {
            // Messages multiplies by (159, 154, 198); a blend filter does not reach the rows from
            // this layer host, so a normal-blended fill that gives the same result on both the
            // blue (72,147,247 -> 45,91,192) and the white text (255 -> 158,158,197).
            l.fillColor = NSColor(srgbRed: 0, green: 0, blue: 102 / 255, alpha: 0.38).cgColor
        } else {
            l.fillColor = NSColor(white: 1, alpha: 0.2).cgColor
        }
        bubbleLayer.addSublayer(l)
        current = l
        refresh()
        fade(l, to: 1, delay: Self.bubbleOnDelay, duration: Self.bubbleOnDuration, timing: .easeInEaseOut)
    }

    func deselectBubble() {
        guard selectedKey != nil, let l = current else { selectedKey = nil; return }
        selectedKey = nil
        current = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        fade(l, to: 0, delay: 0, duration: Self.bubbleOffDuration, timing: .easeOut)
        CATransaction.commit()
    }

    private var current: CAShapeLayer?
    private func fade(_ l: CAShapeLayer, to v: Float, delay: CFTimeInterval, duration: CFTimeInterval, timing: CAMediaTimingFunctionName) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? (v == 1 ? 0 : 1)
        a.toValue = v
        a.beginTime = CACurrentMediaTime() + delay
        a.duration = duration
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(name: timing)
        l.opacity = v
        l.add(a, forKey: "select")
    }

    /// The selected bubble's outline on screen now (nil when its row is not on screen).
    private func selectedBubblePath() -> CGPath? {
        guard let key = selectedKey, let demo = controller.demo else { return nil }
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, spec.key == key, case let .part(p) = spec.kind else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: demo)
            return BubblePath.make(body: body, outgoing: p.outgoing, tail: p.tail).cgPath
        }
        return nil
    }

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

    /// Selects the word at a point (AppKit's double-click word rule). Returns false
    /// when the point is not on text.
    @discardableResult
    func selectWord(at p: CGPoint) -> Bool {
        guard let pos = position(at: p), let demo = controller.demo, let i = demo.model.index[pos.key],
              case let .part(row) = demo.model.rows[i].spec.kind, let tl = row.text else { return false }
        let str = NSAttributedString(string: tl.text)
        guard str.length > 0 else { return false }
        let r = str.doubleClick(at: min(pos.offset, str.length - 1))
        anchor = TextPosition(key: pos.key, offset: r.location)
        focus = TextPosition(key: pos.key, offset: NSMaxRange(r))
        downPoint = nil
        refresh()
        return true
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
        if let l = current { l.path = selectedBubblePath() }
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
