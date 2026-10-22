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
            guard body.maxY > demo.visibleTop, body.minY < demo.anchorY + 20 else { continue }
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
        // cmux: MessagesLab 30495be (TranscriptAccess.swift:75), this file stays at bd65bbf: the
        // elements are kept, one per message id and reused. AX clients hold them between calls; an
        // element made on every call was freed before a client read it (the AX dump's list was empty).
        let visible = visibleMessages()
        let keep = Set(visible.map(\.id))
        selection.axElements = selection.axElements.filter { keep.contains($0.key) }
        return visible.map { m in
            let e = selection.axElements[m.id] ?? MessageAccessibilityElement(messageID: m.id)
            selection.axElements[m.id] = e
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

/// Drag-to-select across rows. The selection is (row key, offset) pairs; each
/// selected row draws its own part of the highlight in its cell
/// (RowCell.selectionHighlight), so the highlight moves with its row's motions,
/// recomputed when the transcript scrolls or changes.
final class TranscriptSelection {
    /// cmux: MessagesLab 30495be: the transcript's accessibility elements, one per visible message id.
    var axElements: [ID: MessageAccessibilityElement] = [:]
    unowned let controller: ChatController
    /// Screen blend of P3 (2.6, 37.7, 85): over the incoming bubble (59, 59, 61) it gives
    /// Messages' highlight (61, 88, 126) and over its text (225) the selected text
    /// (225, 229, 235) (lossless still selected-text.png).
    static let highlightFill = Fixture.p3(2.6, 37.7, 85).cgColor
    private(set) var anchor: TextPosition?
    private(set) var focus: TextPosition?
    private var downPoint: CGPoint?
    private(set) var dragging = false

    init(controller: ChatController) {
        self.controller = controller
    }

    /// cmux: rows renamed in place (old key -> new key: a stream's final message took its rows,
    /// MessagesWindowView.onRowsRenamed). The selection stays on the same text under the new keys.
    func renameRows(_ map: [String: String]) {
        if let a = anchor, let b = map[a.key] { anchor?.key = b }
        if let f = focus, let b = map[f.key] { focus?.key = b }
        if let k = selectedKey, let b = map[k] { selectedKey = b }
    }

    var isEmpty: Bool { anchor == nil || anchor == focus }
    /// cmux: MessagesLab ced183d's NativeScroll asks it (this file stays at bd65bbf): something is
    /// highlighted, a text selection or a selected bubble.
    var showsHighlight: Bool { !isEmpty || selectedKey != nil }

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
            // cmux: MessagesLab 2281879's selection outline (this file stays at bd65bbf): the drawn balloon.
            // cmux: the shared bubble outline (BubblePath.balloon), moved from the cell into the demo view.
            let frame = RowDraw.bodyRect(spec)
            let origin = cell.convert(frame.origin, to: demo)
            var move = CGAffineTransform(translationX: origin.x - frame.minX, y: origin.y - frame.minY)
            return BubblePath.balloon(frame: frame, row: p).cgPath.copy(using: &move)
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
        guard let pos = position(at: p), let g = geometry(key: pos.key), g.length > 0 else { return false }
        let r = g.wordRange(at: min(pos.offset, g.length - 1))
        anchor = TextPosition(key: pos.key, offset: r.location)
        focus = TextPosition(key: pos.key, offset: NSMaxRange(r))
        downPoint = nil
        refresh()
        return true
    }

    /// The drawn text geometry of a row (cmux: the layout the row DRAWS with). A markdown
    /// row's `text` is a one-line proxy of its display string, measured as one line as wide
    /// as the whole string: hit-testing and highlighting through it put the highlight past
    /// the bubble and off the glyphs (scrawl 2026-10-18, "highlighting ... is broken").
    /// Markdown rows use their MarkdownLayout, long rows their tiled layout, plain rows
    /// their TextLayout; offsets are the display string's in every case.
    static func geometry(_ spec: RowSpec) -> RowTextGeometry? {
        guard case let .part(p) = spec.kind, SelText.isText(p.part) else { return nil }
        return p.geometry(width: spec.width)
    }

    private func geometry(key: String) -> RowTextGeometry? {
        guard let demo = controller.demo, let i = demo.model.index.value(for: key),
              let spec = demo.model.rows[checked: i]?.spec else { return nil } // cmux: checked
        return Self.geometry(spec)
    }

    /// The shown cells with text: the cell, its row's model index, key and current spec. The key is
    /// the cell's (a renamed row keeps its cell, whose spec is redrawn on its next configure).
    private func textCells() -> [(cell: RowCell, index: Int, key: String, spec: RowSpec, geometry: RowTextGeometry)] {
        guard let demo = controller.demo else { return [] }
        var out: [(RowCell, Int, String, RowSpec, RowTextGeometry)] = []
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let i = demo.model.index[cell.key], let spec = demo.model.rows[checked: i]?.spec, let g = Self.geometry(spec) else { continue }
            out.append((cell, i, cell.key, spec, g))
        }
        return out
    }

    /// Rows with text, in transcript order (model index); bodies in window content coordinates.
    private func textRows() -> [(index: Int, key: String, geometry: RowTextGeometry, body: CGRect)] {
        guard let demo = controller.demo else { return [] }
        return textCells().map { ($0.index, $0.key, $0.geometry, $0.cell.convert(RowDraw.bodyRect($0.spec), to: demo)) }
            .sorted { $0.0 < $1.0 }
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
        return Self.position(at: p, body: r.body, key: r.key, geometry: r.geometry)
    }

    /// The offset in one row for a point in the same coordinates as `body`.
    static func position(at p: CGPoint, body: CGRect, key: String, geometry g: RowTextGeometry) -> TextPosition {
        if p.y < body.minY { return TextPosition(key: key, offset: 0) }
        if p.y > body.maxY { return TextPosition(key: key, offset: g.length) }
        let local = CGPoint(x: p.x - body.minX, y: p.y - body.minY)
        return TextPosition(key: key, offset: max(0, min(g.offset(at: local), g.length)))
    }

    /// Selected (row key, range) pairs in order, over the loaded rows.
    func selectedRanges() -> [(key: String, range: NSRange, text: String)] {
        guard let demo = controller.demo, let a = anchor, let f = focus, a != f,
              let ia = demo.model.index.value(for: a.key), let fi = demo.model.index.value(for: f.key) else { return [] } // cmux: dictionary reads
        let (s, e) = (ia, a.offset) <= (fi, f.offset) ? (a, f) : (f, a)
        let lo = min(ia, fi), hi = max(ia, fi)
        var out: [(String, NSRange, String)] = []
        for i in lo...hi {
            guard let spec = demo.model.rows[checked: i]?.spec, let g = Self.geometry(spec) else { continue } // cmux: checked
            let key = spec.key
            let len = g.length
            let from = min(key == s.key ? s.offset : 0, len)
            let to = min(key == e.key ? e.offset : len, len)
            guard to > from else { continue }
            let r = NSRange(location: from, length: to - from)
            out.append((key, r, g.substring(r)))
        }
        return out
    }

    var selectedText: String { selectedRanges().map(\.text).joined(separator: "\n") }

    /// The selected range of one row (nil: none of it is selected), without walking the others.
    private func selectedRange(key: String, index i: Int, geometry g: RowTextGeometry) -> NSRange? {
        guard let demo = controller.demo, let a = anchor, let f = focus, a != f,
              let ia = demo.model.index.value(for: a.key), let fi = demo.model.index.value(for: f.key) else { return nil }
        let (s, e) = (ia, a.offset) <= (fi, f.offset) ? (a, f) : (f, a)
        guard i >= min(ia, fi), i <= max(ia, fi) else { return nil }
        let len = g.length
        let from = min(key == s.key ? s.offset : 0, len)
        let to = min(key == e.key ? e.offset : len, len)
        return to > from ? NSRange(location: from, length: to - from) : nil
    }

    /// Highlight rects of one row's selected range, in the coordinates of `body`, only the
    /// lines inside `visible` (same coordinates). Drawn from the row's own geometry, so a
    /// markdown, plain or long row highlights exactly its drawn glyphs, inside its bubble.
    static func highlightRects(_ sel: NSRange, body: CGRect, geometry g: RowTextGeometry, visible: ClosedRange<CGFloat>) -> [CGRect] {
        let v0 = visible.lowerBound - body.minY, v1 = visible.upperBound - body.minY
        guard v1 >= 0, v0 <= body.height else { return [] }
        return g.selectionRects(sel, visible: max(0, v0)...max(0, v1)).compactMap { rect in
            // Never past the bubble (a margin, a wide frag): the highlight stays on the body.
            let r = rect.offsetBy(dx: body.minX, dy: body.minY).intersection(body)
            return r.isNull || r.width <= 0 || r.height <= 0 ? nil : r
        }
    }

    /// Rebuild the highlight for the rows on screen: each selected row draws its part in its own
    /// cell; every other shown cell drops what it drew (a reused cell, a range that shrank).
    func refresh() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let demo = controller.demo {
            for case let cell as RowCell in demo.collection.visibleCells { draw(cell) }
        }
        if let l = current { l.path = selectedBubblePath() }
        CATransaction.commit()
    }

    /// One cell's part of the highlight (MessagesWindowView.onCellDecorated runs it for a cell the
    /// list just configured, so a row that scrolls or springs into view shows its highlight at once).
    func draw(_ cell: RowCell) {
        guard !isEmpty, !cell.isHidden, let demo = controller.demo, let i = demo.model.index[cell.key],
              let spec = demo.model.rows[checked: i]?.spec, let g = Self.geometry(spec),
              let sel = selectedRange(key: cell.key, index: i, geometry: g) else {
            cell.setSelectionHighlight(nil)
            return
        }
        // Lines from a screen above to a screen below the transcript: a row that springs or slides
        // into view brings its highlight along (a long row draws only these lines).
        let h = demo.bounds.height
        let top = cell.convert(CGRect.zero, to: demo).minY
        let visible = (demo.bounds.minY - h - top)...(demo.bounds.maxY + h - top)
        let path = CGMutablePath()
        for rect in Self.highlightRects(sel, body: RowDraw.bodyRect(spec), geometry: g, visible: visible) { path.addRect(rect) }
        cell.setSelectionHighlight(path.isEmpty ? nil : path)
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
