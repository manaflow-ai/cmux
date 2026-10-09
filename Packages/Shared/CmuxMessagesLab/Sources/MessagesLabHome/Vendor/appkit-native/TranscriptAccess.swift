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
    static var messagesList: String { MessagesLabLocalization.string("ax.messages", "Messages", table: "AppKitNative") }
    static var messageRole: String { MessagesLabLocalization.string("ax.message.role", "message", table: "AppKitNative") }
    /// "Attachment: %@"
    static var attachmentFormat: String { MessagesLabLocalization.string("ax.attachment", "Attachment: %@", table: "AppKitNative") }
    static var you: String { MessagesLabLocalization.string("ax.you", "You", table: "AppKitNative") }
    /// sender, text, time
    static var messageFormat: String { MessagesLabLocalization.string("ax.message.format", "%1$@, %2$@, %3$@", table: "AppKitNative") }
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
        case let .custom(c): return CustomRows.plainText(c)
        }
    }

    func accessibilityElements(parent: NSView) -> [NSAccessibilityElement] {
        guard let store, let window = host.window else { return [] }
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        // The elements are kept (one per message id, reused): AX clients hold references to
        // them between calls, and an element made fresh on every call was freed before a
        // client read its frame or value (the rig's AX dump saw an empty list).
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
            // The selected part of this message's first text part (AXSelectedText, AXSelectedTextRange).
            e.setAccessibilitySelectedText(nil)
            e.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 0))
            if let st = selection.state, !st.isEmpty, let seq = selection.seq(of: m.id), seq >= st.lo.seq, seq <= st.hi.seq,
               let r = st.range(seq: seq, part: 0, length: (m.text as NSString).length) {
                e.setAccessibilitySelectedTextRange(r)
                e.setAccessibilitySelectedText((m.text as NSString).substring(with: r))
            }
            MarkdownAccess.decorate(e, self, id: m.id)      // markdown structure (MarkdownAccess.swift)
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
    /// The whole selection as copied (loaded rows; empty when it reaches unloaded rows).
    override func accessibilitySelectedText() -> String? {
        guard let sel = controller?.selection, !sel.isEmpty else { return nil }
        return sel.selectedTextLoaded
    }
    override func accessibilitySelectedTextRange() -> NSRange {
        guard let t = accessibilitySelectedText() else { return NSRange(location: 0, length: 0) }
        return NSRange(location: 0, length: (t as NSString).length)
    }
}

// MARK: Selection

/// Transcript text selection (SELECTION.md). The state is in model space (`SelState`,
/// catalyst/Sources/Selection.swift): message sequence, part, text offset. This class maps
/// points to positions over the LOADED model rows (also off screen, so a drag past an edge
/// keeps a real focus), draws the highlight for the rows on screen, runs the drag
/// autoscroll, and copies (rows outside the loaded window are read from the pager's source
/// off main).
final class TranscriptSelection {
    unowned let controller: ChatController
    /// Text highlight over incoming and outgoing text (screen blend, see init).
    let layer = CAShapeLayer()
    let outLayer = CAShapeLayer()
    /// Non-text parts inside a selection (photos, link cards): their bubble gets the
    /// clicked-bubble look.
    let atomLayer = CAShapeLayer(), atomOutLayer = CAShapeLayer()
    private(set) var state: SelState? {
        didSet {
            guard state != oldValue else { return }
            let doc = controller.host.scrollView.document
            if let sc = scratch {
                // The scratch view kept the focus for the menu's actions (Translate, Writing Tools).
                // cmux: the pane's window is optional.
                if controller.window?.firstResponder === sc { controller.window?.makeFirstResponder(isEmpty ? nil : doc) }
                sc.removeFromSuperview(); scratch = nil
            }
            NSAccessibility.post(element: doc, notification: .selectedTextChanged)
        }
    }
    /// Accessibility elements of the visible messages, by message id (ChatController.accessibilityElements).
    var axElements: [ID: MessageAccessibilityElement] = [:]
    private var downPoint: CGPoint?
    private var downPos: SelPos?
    private(set) var dragging = false
    /// The pointer of the drag in progress (window content coordinates).
    private var pointer: CGPoint?
    /// Window active: the active highlight; inactive: Messages' grey one.
    var windowActive = true { didSet { if oldValue != windowActive { applyColors(); refresh() } } }

    init(controller: ChatController) {
        self.controller = controller
        for l in [layer, outLayer, atomLayer, atomOutLayer, bubbleLayer] { l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "fillColor": NSNull()] }
        // Screen blend of P3 (2.6, 37.7, 85): over the incoming bubble (59, 59, 61) it gives
        // Messages' highlight (61, 88, 126) and over its text (225) the selected text
        // (225, 229, 235) (lossless still selected-text.png).
        layer.compositingFilter = "screenBlendMode"
        applyColors()
    }

    private func applyColors() {
        layer.fillColor = (windowActive ? SelectionColors.incomingActive : SelectionColors.incomingInactive).cgColor
        outLayer.fillColor = (windowActive ? SelectionColors.outgoingActive : SelectionColors.outgoingInactive).cgColor
        atomLayer.fillColor = SelectionColors.attachment.cgColor
        atomOutLayer.fillColor = SelectionColors.attachment.cgColor
    }

    var isEmpty: Bool { state?.isEmpty ?? true }

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

    // MARK: Model mapping

    private var seqMap: (start: Int, count: Int, first: ID?, last: ID?, map: [ID: Int]) = (0, 0, nil, nil, [:])
    /// The history sequence of a loaded message.
    func seq(of id: ID) -> Int? {
        guard let st = controller.store?.state else { return nil }
        let ms = st.conversation.messages
        if seqMap.start != st.windowStart || seqMap.count != ms.count || seqMap.first != ms.first?.id || seqMap.last != ms.last?.id {
            var m = [ID: Int](minimumCapacity: ms.count)
            for (i, x) in ms.enumerated() { m[x.id] = st.windowStart + i }
            seqMap = (st.windowStart, ms.count, ms.first?.id, ms.last?.id, m)
        }
        return seqMap.map[id]
    }

    /// A loaded part row: model index, spec, part row and its body in window coordinates.
    struct RowRef { var index: Int; var spec: RowSpec; var row: PartRow; var body: CGRect; var seq: Int }

    private func rowRef(_ i: Int) -> RowRef? {
        guard let demo = controller.demo, i >= 0, i < demo.model.count, !demo.model.rows[i].ghost,
              case let .part(p) = demo.model.rows[i].spec.kind, let seq = seq(of: p.ref.messageId) else { return nil }
        let spec = demo.model.rows[i].spec
        let b = RowDraw.bodyRect(spec)
        let y = demo.windowY(contentY: demo.layout.contentTop(i))
        return RowRef(index: i, spec: spec, row: p, body: CGRect(x: b.minX, y: y, width: b.width, height: b.height), seq: seq)
    }

    /// The text position nearest to a window point, over every loaded row (on screen or not).
    /// Between two bubbles the upper half of the gap ends the row above, the lower half starts
    /// the row below (the same text either way); past the loaded rows: their first or last
    /// position.
    func position(at p: CGPoint) -> SelPos? {
        guard let demo = controller.demo, demo.model.count > 0 else { return nil }
        let my = p.y - MessagesWindowView.cvTop + demo.collection.contentOffset.y - demo.layout.rowsTop
        let r = demo.model.range(my - 1, my + 1)
        var above: RowRef?, below: RowRef?
        // Nearest part rows above and below the point (walk outward from the hit range).
        var i = min(demo.model.count - 1, max(0, r.upperBound - 1))
        while i >= 0 {
            if let x = rowRef(i) {
                if x.body.minY <= p.y { if x.body.maxY >= p.y { return pos(in: x, p) }; above = x; break }
                below = x
            }
            i -= 1
        }
        if below.map({ $0.body.minY < p.y }) ?? true { // cmux: no force unwrap
            var j = r.upperBound
            while j < demo.model.count { if let x = rowRef(j), x.body.minY > p.y { below = x; break }; j += 1 }
        }
        switch (above, below) {
        case let (a?, b?): return p.y < (a.body.maxY + b.body.minY) / 2 ? end(of: a) : start(of: b)
        case let (a?, nil): return end(of: a)
        case let (nil, b?): return start(of: b)
        default: return nil
        }
    }
    private func start(of x: RowRef) -> SelPos { SelPos(seq: x.seq, part: x.row.ref.partIndex, offset: 0) }
    private func end(of x: RowRef) -> SelPos { SelPos(seq: x.seq, part: x.row.ref.partIndex, offset: SelText.length(x.row.part, message: x.row.ref.messageId, format: x.row.format)) }
    private func pos(in x: RowRef, _ p: CGPoint) -> SelPos {
        let local = CGPoint(x: p.x - x.body.minX, y: p.y - x.body.minY)
        let off: Int
        if let g = x.row.geometry(width: x.spec.width) { off = g.offset(at: local) } else { off = local.y < x.body.height / 2 ? 0 : 1 }
        return SelPos(seq: x.seq, part: x.row.ref.partIndex, offset: off)
    }

    /// The row under a point (body, 4 pt slop), for unit selection.
    private func row(at p: CGPoint) -> RowRef? {
        guard let demo = controller.demo else { return nil }
        let my = p.y - MessagesWindowView.cvTop + demo.collection.contentOffset.y - demo.layout.rowsTop
        for i in demo.model.range(my - 1, my + 1) { if let x = rowRef(i), x.body.insetBy(dx: -4, dy: -4).contains(p) { return x } }
        return nil
    }

    /// The word or paragraph around a position (a whole part for non-text parts).
    func unitRange(_ unit: SelUnit, at p: CGPoint) -> ClosedRange<SelPos>? {
        guard let at = position(at: p) else { return nil }
        guard unit != .character else { return at...at }
        guard let x = row(at: p) ?? nearestRow(at) else { return at...at }
        let part = x.row.ref.partIndex
        guard let g = x.row.geometry(width: x.spec.width) else {
            return SelPos(seq: x.seq, part: part, offset: 0)...SelPos(seq: x.seq, part: part, offset: 1)
        }
        // The character under the pointer (not the nearest caret position) decides the unit.
        var o = at.offset
        if let sg = g as? ShortTextGeometry, x.body.insetBy(dx: -4, dy: -4).contains(p) {
            o = sg.characterIndex(at: CGPoint(x: p.x - x.body.minX, y: p.y - x.body.minY))
        }
        let r = unit == .word ? g.wordRange(at: o) : g.paragraphRange(at: o)
        return SelPos(seq: x.seq, part: part, offset: r.location)...SelPos(seq: x.seq, part: part, offset: NSMaxRange(r))
    }
    private func nearestRow(_ at: SelPos) -> RowRef? {
        guard let demo = controller.demo else { return nil }
        for i in demo.model.rows.indices { if let x = rowRef(i), x.seq == at.seq, x.row.ref.partIndex == at.part { return x } }
        return nil
    }

    // MARK: Gestures

    /// A press: count 1 starts a character drag (a click without a drag clears); 2 selects
    /// the word, 3 the paragraph, and a drag then extends by that unit. Shift extends the
    /// current selection to the press.
    func mouseDown(_ p: CGPoint, count: Int = 1, shift: Bool = false) {
        // The thread and reply views have no text selection (their rows are copies).
        if controller.demo?.threadOpen == true { downPoint = nil; return }
        pointer = p
        if shift, let s = state, !s.isEmpty, let f = unitRange(s.unit, at: p) {
            // AppKit: the end of the selection farther from the press stays (the anchor); the
            // other end moves to the press, by the selection's unit; a drag continues from there.
            let anchor: SelPos
            if f.lowerBound < s.lo { anchor = s.hi }
            else if f.upperBound > s.hi { anchor = s.lo }
            else if s.lo.seq == s.hi.seq && s.lo.part == s.hi.part { anchor = f.lowerBound.offset - s.lo.offset < s.hi.offset - f.lowerBound.offset ? s.hi : s.lo }
            else { anchor = s.lo }
            // Real Messages extends by characters (sel-real-real-shift-click: "Roose … publis").
            var n = SelState(unit: .character, origin: anchor...anchor)
            if let c = position(at: p) { n.extend(to: c...c) } else { n.extend(to: f) }
            state = n
            downPoint = p; dragging = true
            refresh()
            return
        }
        if count >= 2 {
            let unit: SelUnit = count == 2 ? .word : .paragraph
            guard let r = unitRange(unit, at: p) else { return }
            state = SelState(unit: unit, origin: r)
            downPoint = p; dragging = true
            refresh()
            return
        }
        // A press on the highlight keeps the selection: a drag from there drags the text out
        // (real Messages: sel-real-real-right-click-selection, a press inside a selection starts a
        // text drag); a click without a drag clears it on the release.
        if !isEmpty, highlightContains(p) {
            textDragFrom = p
            downPoint = nil; dragging = false
            return
        }
        downPoint = p
        downPos = position(at: p)
        dragging = false
        clear()
    }
    private var textDragFrom: CGPoint?
    var textDragging: Bool { textDragFrom != nil }

    /// Returns true when the drag selects (it is not a click).
    @discardableResult
    func mouseDragged(_ p: CGPoint, event: NSEvent? = nil) -> Bool {
        if let f = textDragFrom {
            guard hypot(p.x - f.x, p.y - f.y) > 3 else { return true }
            textDragFrom = nil
            if let event { beginTextDrag(event) }
            return true
        }
        guard let d = downPoint else { return false }
        pointer = p
        if !dragging {
            guard hypot(p.x - d.x, p.y - d.y) > 3, let a = downPos ?? position(at: d) else { return false }
            dragging = true
            state = SelState(unit: .character, origin: a...a)
        }
        updateFocus()
        autoscroll()
        return true
    }

    private func updateFocus() {
        guard let p = pointer, var s = state else { return }
        let q = clampForFocus(p)
        // Real Messages (sel-real-real-drag-cross-sender): once the pointer is inside another
        // bubble than the one the drag started in, that whole bubble is selected (the start
        // bubble keeps its partial range); in the gap between bubbles nothing of the next one.
        let f: ClosedRange<SelPos>
        if let x = row(at: q), x.seq != s.origin.lowerBound.seq || x.row.ref.partIndex != s.origin.lowerBound.part {
            let part = x.row.ref.partIndex, len = x.row.geometry(width: x.spec.width)?.length ?? SelText.length(x.row.part, message: x.row.ref.messageId, format: x.row.format)
            f = SelPos(seq: x.seq, part: part, offset: 0)...SelPos(seq: x.seq, part: part, offset: len)
        } else {
            guard let u = unitRange(s.unit, at: q) else { return }
            f = u
        }
        s.extend(to: f)
        if s != state { state = s; refresh() }
    }

    /// The point used for the focus: inside the transcript's visible band, so an autoscroll
    /// past the top or bottom edge selects to the edge row (AppKit).
    private func clampForFocus(_ p: CGPoint) -> CGPoint {
        guard let demo = controller.demo else { return p }
        return CGPoint(x: p.x, y: min(max(p.y, Fixture.headerHeight + 1), demo.anchorY - 1))
    }

    func mouseUp() -> Bool {
        if textDragFrom != nil { textDragFrom = nil; clear(); return false }
        defer { downPoint = nil; downPos = nil; dragging = false; pointer = nil; stopAutoscroll() }
        return dragging
    }

    func clear() {
        state = nil
        refresh()
    }
    func setState(_ s: SelState?) { state = s; refresh() }

    /// Selects the word at a point. Returns false when the point is not on text.
    @discardableResult
    func selectWord(at p: CGPoint) -> Bool {
        mouseDown(p, count: 2)
        downPoint = nil; dragging = false
        return !isEmpty
    }

    /// Cmd-A in the transcript: the whole history (SELECTION.md).
    func selectAll() {
        guard let st = controller.store?.state, st.total > 0 else { return }
        let last = st.total - 1
        state = SelState(unit: .character, origin: SelPos(seq: 0, part: 0, offset: 0)...SelPos(seq: last, part: Int.max, offset: Int.max))
        refresh()
    }

    // MARK: Autoscroll

    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// Points per second for a pointer `over` points past the edge (SELECTION.md, measured).
    static func autoscrollSpeed(_ over: CGFloat) -> CGFloat {
        let d = abs(over)
        return min(SelectionLook.autoscrollMax, SelectionLook.autoscrollBase + SelectionLook.autoscrollGain * d)
    }
    private func overEdge() -> CGFloat {
        guard let p = pointer, let demo = controller.demo else { return 0 }
        if p.y < Fixture.headerHeight { return p.y - Fixture.headerHeight }
        if p.y > demo.anchorY { return p.y - demo.anchorY }
        return 0
    }
    private func autoscroll() {
        guard overEdge() != 0, link == nil else { return }
        let l = controller.host.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = CACurrentMediaTime()
    }
    private func stopAutoscroll() { link?.invalidate(); link = nil }
    @objc private func tick(_ l: CADisplayLink) {
        let over = overEdge()
        guard dragging, over != 0, let demo = controller.demo else { stopAutoscroll(); return }
        let now = CACurrentMediaTime(), dt = min(0.05, max(0.001, now - lastTick))
        lastTick = now
        let v = Self.autoscrollSpeed(over) * (over < 0 ? -1 : 1)
        let y0 = demo.collection.contentOffset.y
        let y = min(max(y0 + v * CGFloat(dt), demo.minOffset), demo.pinnedOffset)
        guard abs(y - y0) > 0.01 else { return }
        let t0 = CACurrentMediaTime()
        // One highlight rebuild per frame (the scroll and the focus change both ask for one).
        inTick = true
        controller.host.scrollView.scroll(toModelOffset: y)
        TranscriptSelection.autoscrollTicks += 1
        updateFocus()
        inTick = false
        if refreshPending { refreshPending = false; refresh() }
        Self.tickMsMax = max(Self.tickMsMax, (CACurrentMediaTime() - t0) * 1000)
    }
    static var autoscrollTicks = 0
    /// Bench: the slowest autoscroll tick (scroll + focus + highlight) and highlight rebuild, ms.
    static var tickMsMax = 0.0, refreshMsMax = 0.0

    // MARK: Highlight

    /// Rebuild the highlight for the rows on screen.
    /// Body-local highlight rects of short text rows, by row key, width and range (a drag with
    /// autoscroll rebuilds the highlight every frame; Core Text line work only when one changes).
    private var rectCache: [String: [CGRect]] = [:]
    private var inTick = false, refreshPending = false
    func refresh() {
        if inTick { refreshPending = true; return }
        let t0 = CACurrentMediaTime()
        defer { Self.refreshMsMax = max(Self.refreshMsMax, (CACurrentMediaTime() - t0) * 1000) }
        if rectCache.count > 1024 { rectCache.removeAll(keepingCapacity: true) }
        let inPath = CGMutablePath(), outPath = CGMutablePath(), atomIn = CGMutablePath(), atomOut = CGMutablePath()
        if let s = state, !s.isEmpty, let demo = controller.demo {
            let top = Fixture.headerHeight - 20, bottom = demo.anchorY + 20
            for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
                guard let spec = cell.spec, case let .part(p) = spec.kind, let seq = seq(of: p.ref.messageId) else { continue }
                let g = p.geometry(width: spec.width)
                guard let r = s.range(seq: seq, part: p.ref.partIndex, length: g?.length ?? SelText.length(p.part, message: p.ref.messageId, format: p.format)) else { continue }
                let body = cell.convert(RowDraw.bodyRect(spec), to: demo)
                guard body.maxY > top, body.minY < bottom else { continue }
                if let g {
                    let path = p.outgoing ? outPath : inPath
                    let rects: [CGRect]
                    if g is ShortTextGeometry {
                        let k = "\(spec.key)|\(spec.width)|\(r.location)|\(r.length)"
                        if let c = rectCache[k] { rects = c } else {
                            rects = g.selectionRects(r, visible: -1e6...1e6); rectCache[k] = rects
                        }
                    } else {
                        rects = g.selectionRects(r, visible: (top - body.minY)...(bottom - body.minY))
                    }
                    for rect in rects {
                        path.addRect(rect.offsetBy(dx: body.minX, dy: body.minY))
                    }
                } else {
                    (p.outgoing ? atomOut : atomIn).addPath(BubblePath.make(body: body, outgoing: p.outgoing, tail: p.tail).cgPath)
                }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.path = inPath.isEmpty ? nil : inPath
        outLayer.path = outPath.isEmpty ? nil : outPath
        atomLayer.path = atomIn.isEmpty ? nil : atomIn
        atomOutLayer.path = atomOut.isEmpty ? nil : atomOut
        if let l = current { l.path = selectedBubblePath() }
        CATransaction.commit()
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

    // MARK: Text menu

    /// Whether a window point is on the highlight.
    func highlightContains(_ p: CGPoint) -> Bool {
        [layer.path, outLayer.path, atomLayer.path, atomOutLayer.path].contains { $0?.contains(p) == true }
    }

    /// Real Messages (macOS 27, sel-real-real-right-click-selection): a right-click on selected
    /// text opens the text menu: Look Up “…”, Translate “…”, Search With Google, Copy, Share…,
    /// Writing Tools, Speech, Services. Ours: Look Up, Search With Google, Copy, Share…, Speech
    /// (Translate, Writing Tools and Services need a text view; SELECTION.md).
    func textMenu(at p: CGPoint) -> NSMenu? {
        guard !isEmpty, highlightContains(p), let text = selectedTextLoaded, !text.isEmpty else { return nil }
        if !ProcessInfo.processInfo.arguments.contains("--own-text-menu"), let m = systemTextMenu(at: p, text: text) { return m }
        defer { SelectionCheck.logMenu(menuTitles) }
        let short = text.count > 26 ? String(text.prefix(26)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" : text
        let menu = NSMenu()
        let host = controller.host
        menu.addItem(MenuAction(title: String(format: NativeStrings.lookUpFormat, short)) {
            host.showDefinition(for: NSAttributedString(string: text, attributes: [.font: Fixture.bodyFont]), at: p)
        })
        menu.addItem(MenuAction(title: NativeStrings.searchWithGoogle) {
            // cmux: no force unwrap.
            guard var c = URLComponents(string: "https://www.google.com/search") else { return }
            c.queryItems = [URLQueryItem(name: "q", value: text)]
            if let u = c.url { NSWorkspace.shared.open(u) }
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: NativeStrings.copy) { [weak self] in self?.copy() })
        menu.addItem(MenuAction(title: NativeStrings.share) {
            NSSharingServicePicker(items: [text]).show(relativeTo: CGRect(origin: p, size: CGSize(width: 1, height: 1)), of: host, preferredEdge: .minY)
        })
        menu.addItem(.separator())
        let speech = NSMenuItem(title: NativeStrings.speech, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(MenuAction(title: NativeStrings.startSpeaking) { TranscriptSelection.speaker.startSpeaking(text) })
        sub.addItem(MenuAction(title: NativeStrings.stopSpeaking) { TranscriptSelection.speaker.stopSpeaking() })
        speech.submenu = sub
        menu.addItem(speech)
        menuTitles = menu.items.map(\.title).filter { !$0.isEmpty }
        return menu
    }
    static let speaker = NSSpeechSynthesizer()
    private var menuTitles: [String] = []

    // MARK: Text drag

    /// Drags the selected text (the Cmd-C content: the same pasteboard item) with an image of
    /// its first lines.
    private func beginTextDrag(_ event: NSEvent) {
        guard let s = state, let msgs = loadedMessages(s) else { return }
        let (item, plain) = Self.pasteboardItem(SelectionCopy.pieces(s, msgs), names: names(), extra: [])
        let doc = controller.host.scrollView.document
        let di = NSDraggingItem(pasteboardWriter: item)
        let shown = plain.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n")
        let str = NSAttributedString(string: shown, attributes: [.font: Fixture.bodyFont, .foregroundColor: NSColor.labelColor])
        let size = str.boundingRect(with: CGSize(width: 360, height: 200), options: [.usesLineFragmentOrigin]).size
        let img = NSImage(size: CGSize(width: ceil(size.width) + 4, height: ceil(size.height) + 4), flipped: true) { _ in
            str.draw(with: CGRect(x: 2, y: 2, width: size.width, height: size.height), options: [.usesLineFragmentOrigin]); return true
        }
        let at = doc.convert(event.locationInWindow, from: nil)
        di.setDraggingFrame(CGRect(x: at.x - 8, y: at.y - 8, width: img.size.width, height: img.size.height), contents: img)
        doc.beginDraggingSession(with: [di], event: event, source: doc)
        TranscriptSelection.textDrags += 1
    }
    static var textDrags = 0

    // MARK: System text menu

    /// The system's own text menu items (Look Up, Translate, Search With Google, Copy, Share…,
    /// Writing Tools, Speech, Services) come from a scratch NSTextView that holds the selected
    /// text, invisible, over the highlight; it is first responder while the menu is open (and
    /// while a Translate popover or Writing Tools panel uses it). Copy is ours (Messages' format).
    private var scratch: NSTextView?
    let menuWatcher = TextMenuWatcher()
    func systemTextMenu(at p: CGPoint, text: String) -> NSMenu? {
        let host = controller.host
        scratch?.removeFromSuperview()
        let bounds = [layer.path, outLayer.path].compactMap { $0?.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
        let f = bounds.isNull ? CGRect(x: p.x, y: p.y, width: 300, height: 16) : bounds
        let tv = ScratchTextView(frame: f)
        tv.selection = self
        tv.string = text
        tv.font = Fixture.bodyFont
        tv.textColor = .clear
        tv.drawsBackground = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.selectedTextAttributes = [.backgroundColor: NSColor.clear, .foregroundColor: NSColor.clear]
        // Never visible (an inactive selection would draw grey over the bubble); its frame still
        // anchors the Translate popover and Look Up.
        tv.alphaValue = 0
        tv.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        host.addSubview(tv)
        scratch = tv
        tv.usesFontPanel = false
        // Services in the text menu (AppKit adds them to a context menu when the app has a
        // Services menu and registered send types).
        NSApp.registerServicesMenuSendTypes([.string, .rtf], returnTypes: [])
        let win = controller.window
        let cur = NSApp.currentEvent
        // cmux: the pane's window is optional.
        let e = cur.flatMap { [.rightMouseDown, .leftMouseDown].contains($0.type) ? $0 : nil }
            ?? NSEvent.mouseEvent(with: .rightMouseDown, location: host.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: win?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        guard let e, let menu = tv.menu(for: e) else { return nil }
        // Messages' text menu has no Cut, Paste or Font (the text is not editable).
        let drop: Set<Selector> = [#selector(NSText.cut(_:)), #selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)),
                                   #selector(NSTextView.pasteAsRichText(_:)), #selector(NSText.delete(_:))]
        for it in menu.items.reversed() {
            // Font, Spelling and Grammar, Substitutions: editing submenus (by their items' actions).
            let editing: Set<Selector> = [#selector(NSFontManager.orderFrontFontPanel(_:)), #selector(NSText.showGuessPanel(_:)),
                                          #selector(NSTextView.orderFrontSubstitutionsPanel(_:))]
            let fontMenu = it.submenu?.items.contains { $0.action.map(editing.contains) == true } == true
            if let a = it.action, drop.contains(a) { menu.removeItem(it) } else if fontMenu { menu.removeItem(it) }
        }
        // Collapse separators left next to each other.
        var prevSep = true
        for it in menu.items { if it.isSeparatorItem { if prevSep { menu.removeItem(it) } else { prevSep = true } } else { prevSep = false } }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) } // cmux: no force unwrap
        // Our Copy (Messages' cross-bubble format) instead of the scratch view's.
        for it in menu.items where it.action == #selector(NSText.copy(_:)) {
            it.target = menuWatcher; it.action = #selector(TextMenuWatcher.copy(_:))
        }
        menuWatcher.selection = self
        // Services as Messages shows them: a submenu that AppKit fills with the services for the
        // focused text (the scratch view) when it opens. The context-menu plug-in lookup stays
        // off (6-8 ms per open, perf lane bd44207); the submenu is filled lazily, on its open.
        menu.allowsContextMenuPlugIns = false
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        let services = NSMenuItem(title: NativeStrings.services, action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: NativeStrings.services)
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.delegate = menuWatcher
        controller.window?.makeFirstResponder(tv)  // cmux: the pane's window is optional
        return menu
    }

    // MARK: Text and copy

    private func names() -> (ID) -> String {
        guard let st = controller.store?.state else { return { $0 } }
        let ps = st.conversation.participants
        return { id in ps.first { $0.id == id }.map { $0.isMe ? NativeStrings.me : $0.displayName } ?? id }
    }

    /// The loaded messages of the selection, or nil when it reaches outside the window.
    private func loadedMessages(_ s: SelState) -> [(Int, Message)]? {
        guard let st = controller.store?.state else { return nil }
        let ms = st.conversation.messages, w = st.windowStart
        guard s.lo.seq >= w, s.hi.seq < w + ms.count else { return nil }
        return (s.lo.seq...s.hi.seq).map { ($0, ms[$0 - w]) }
    }

    /// The selected text when every selected row is loaded (accessibility, tests); nil otherwise.
    var selectedTextLoaded: String? {
        guard let s = state, !s.isEmpty, let msgs = loadedMessages(s) else { return state == nil ? "" : nil }
        return SelectionCopy.plain(SelectionCopy.pieces(s, msgs), names: names())
    }
    var selectedText: String { selectedTextLoaded ?? "" }

    static let copyQueue = DispatchQueue(label: "selection.copy", qos: .userInitiated)
    /// Copies (Cmd-C, the menu): synchronously when the selection is loaded, else the
    /// messages outside the window are decoded off main and the pasteboard is written when
    /// they are in (the main thread never waits for I/O).
    func copy(_ done: (() -> Void)? = nil) {
        // A clicked (selected) message without a text selection copies whole (real Messages:
        // sel-real-real-click-bubble-copy).
        if isEmpty, let key = selectedKey, let demo = controller.demo, let i = demo.model.index[key], let x = rowRef(i) {
            let len = x.row.geometry(width: x.spec.width)?.length ?? SelText.length(x.row.part, message: x.row.ref.messageId, format: x.row.format)
            let whole = SelState(unit: .character, origin: SelPos(seq: x.seq, part: x.row.ref.partIndex, offset: 0)...SelPos(seq: x.seq, part: x.row.ref.partIndex, offset: len))
            if let msgs = loadedMessages(whole) { Self.write(SelectionCopy.pieces(whole, msgs), names: names(), extra: []); SelectionCheck.log(whole, plain: Self.lastCopy ?? "") }
            done?()
            return
        }
        guard let s = state, !s.isEmpty else { return }
        let names = names()
        if let msgs = loadedMessages(s) {
            Self.write(SelectionCopy.pieces(s, msgs), names: names, extra: markdownItems(s))
            SelectionCheck.log(s, plain: Self.lastCopy ?? "")
            done?()
            return
        }
        guard let src = controller.pager?.source else { return }
        let total = controller.store?.state.total ?? 0  // cmux: the pane's store is optional
        Self.copyQueue.async {
            var pieces: [SelectionCopy.Piece] = []
            var a = s.lo.seq
            let b = min(s.hi.seq, total - 1)
            while a <= b {
                let e = min(b + 1, a + 2000)
                let page = src.decode(a..<e)
                pieces += SelectionCopy.pieces(s, page.enumerated().map { (a + $0.offset, $0.element) })
                a = e
            }
            DispatchQueue.main.async { Self.write(pieces, names: names, extra: []); SelectionCheck.log(s, plain: Self.lastCopy ?? ""); done?() }
        }
    }

    /// Markdown parts give their own rich types when one part is selected.
    private func markdownItems(_ s: SelState) -> [(type: String, data: Data)] {
        guard s.lo.seq == s.hi.seq, s.lo.part == s.hi.part, let demo = controller.demo else { return [] }
        for i in demo.model.rows.indices {
            guard let x = rowRef(i), x.seq == s.lo.seq, x.row.ref.partIndex == s.lo.part, let g = x.row.markdownGeometry,
                  let r = s.range(seq: x.seq, part: s.lo.part, length: g.length) else { continue }
            return g.pasteboardItems(r).filter { $0.type != NSPasteboard.PasteboardType.string.rawValue }
        }
        return []
    }

    static func write(_ pieces: [SelectionCopy.Piece], names: (ID) -> String, extra: [(type: String, data: Data)]) {
        let (item, plain) = pasteboardItem(pieces, names: names, extra: extra)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
        lastCopy = plain
    }
    /// One pasteboard item for Copy and for a text drag (the same content).
    static func pasteboardItem(_ pieces: [SelectionCopy.Piece], names: (ID) -> String, extra: [(type: String, data: Data)]) -> (NSPasteboardItem, String) {
        let plain = SelectionCopy.plain(pieces, names: names)
        let rich = SelectionCopy.rich(pieces, names: names)
        // Real Messages writes these three types (sel-real-* pb.json): a UIKit attributed-string
        // archive, flat RTFD and UTF-8 plain text.
        let item = NSPasteboardItem()
        if let a = try? NSKeyedArchiver.archivedData(withRootObject: rich, requiringSecureCoding: false) {
            item.setData(a, forType: NSPasteboard.PasteboardType("com.apple.uikit.attributedstring"))
        }
        if let rtfd = rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            item.setData(rtfd, forType: .rtfd)
        }
        item.setString(plain, forType: .string)
        for x in extra { item.setData(x.data, forType: NSPasteboard.PasteboardType(x.type)) }
        return (item, plain)
    }
    /// The last plain text written (self-test).
    static var lastCopy: String?
}

extension ChatController {
    /// Text dropped on the compose field (a text drag out of the transcript, or from another
    /// app): the field takes it at its caret. Only text without files or images; only over the field.
    func textDropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = textDropOperationImpl(sender)
        let q = host.convert(sender.draggingLocation, from: nil)
        SelectionCheck.logEvent("textDropOp", ["op": Int(truncatingIfNeeded: op.rawValue), "x": Double(q.x), "y": Double(q.y)])
        return op
    }
    private func textDropOperationImpl(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let demo, sender.draggingPasteboard.string(forType: .string) != nil,
              (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []).isEmpty else { return [] }
        let p = host.convert(sender.draggingLocation, from: nil)
        return demo.compose.fieldRect.insetBy(dx: -4, dy: -4).contains(p) ? .copy : []
    }
    func performTextDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let s = sender.draggingPasteboard.string(forType: .string), let tv = demo?.compose.textView.view else { return false }
        window?.makeFirstResponder(tv)  // cmux: the pane's window is optional
        // Messages' plain text has CR line ends; the field uses LF.
        tv.insertText(s.replacingOccurrences(of: "\r", with: "\n"), replacementRange: tv.selectedRange())
        SelectionCheck.logEvent("textDropped", ["chars": (s as NSString).length])
        return true
    }
}

/// Text menu delegate: logs the titles the menu shows (e2e), routes Copy to the selection and
/// gives the focus back to the transcript when the menu closes.
final class TextMenuWatcher: NSObject, NSMenuDelegate {
    weak var selection: TranscriptSelection?
    func menuWillOpen(_ menu: NSMenu) { openedAt = ProcessInfo.processInfo.systemUptime; closedAt = .infinity; SelectionCheck.logMenu(menu.items.map(\.title).filter { !$0.isEmpty }) }
    func menuDidClose(_ menu: NSMenu) {
        closedAt = ProcessInfo.processInfo.systemUptime
        SelectionCheck.logMenu(menu.items.map(\.title).filter { !$0.isEmpty })   // with items AppKit added late (Services)
    }
    private(set) var openedAt: TimeInterval = .infinity, closedAt: TimeInterval = 0
    /// Whether a key event happened while the menu was open (the Esc that closed it).
    func happenedWhileOpen(_ e: NSEvent) -> Bool { e.timestamp >= openedAt && e.timestamp <= closedAt }
    @objc func copy(_ sender: Any?) { selection?.copy() }
}

/// The scratch view of the system text menu: Cmd-C and Copy give Messages' format; it never draws.
final class ScratchTextView: NSTextView {
    weak var selection: TranscriptSelection?
    override func copy(_ sender: Any?) { selection?.copy() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension TranscriptDocumentView: NSDraggingSource {
    /// Copy and generic: NSTextView (the compose field) takes a text drop only with .generic in
    /// the mask (it refused a .copy-only drag: operation 0 at the field).
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .generic] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        SelectionCheck.logEvent("textDragEnded", ["operation": Int(truncatingIfNeeded: operation.rawValue)])
    }
}

/// Services (the text menu's Services items, AppKit's standard path): the transcript and the
/// window's host view offer the selected text as plain and rich text; they take nothing back.
extension TranscriptDocumentView: NSServicesMenuRequestor {
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, let t = sendType, [.string, .rtf].contains(t), controller?.selection.isEmpty == false { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let text = controller?.selection.selectedTextLoaded, !text.isEmpty else { return false }
        pboard.clearContents()
        pboard.setString(text.replacingOccurrences(of: "\r", with: "\n"), forType: .string)
        return true
    }
}
extension HostView: NSServicesMenuRequestor {
    // The document view's own check, not its validRequestor (its super walks up to this view).
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, let t = sendType, [.string, .rtf].contains(t), let c = controller, !c.selection.isEmpty { return c.host.scrollView.document }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        controller?.host.scrollView.document.writeSelection(to: pboard, types: types) ?? false
    }
}

/// Highlight colors (SELECTION.md: measured on lossless real-Messages frames).
enum SelectionColors {
    /// Incoming: screen-blended over the grey bubble: (59,59,61) -> (61,88,126), text 225 ->
    /// (225,229,235) (sel-real-real-drag-in-bubble frame 103: 16 pt line slots from 7 pt under
    /// the bubble top).
    static var incomingActive = Fixture.p3(2.6, 37.7, 85)
    /// Outgoing: white at 0.648 (normal blend): blue (73,147,247) -> (191,217,252), the white
    /// text stays white (sel-real-real-drag-cross-sender frame 106).
    static var outgoingActive = NSColor(white: 1, alpha: 0.648)
    /// Inactive window: the same colors (sel-r3-real3-inactive: with Calculator frontmost the
    /// header and compose glass change, the transcript does not, highlight stays (61,88,126)).
    static var incomingInactive = incomingActive
    static var outgoingInactive = outgoingActive
    /// A photo inside a selection: grey 127 at 0.326 over it (out = 0.674 x in + 41.5,
    /// sel-real-real-drag-cross-sender frames 80 -> 100).
    static var attachment = NSColor(white: 0.5, alpha: 0.326)
}

extension SelectionLook {
    /// Real Messages: a steady 415 pt/s with the pointer 40 pt past the transcript's top edge
    /// (sel-real-real-autoscroll-top, 0.29-1.55 s: 524 pt in 1.26 s; no acceleration with time).
    static var autoscrollBase: CGFloat = 0
    static var autoscrollGain: CGFloat = 10.4
    static var autoscrollMax: CGFloat = 6000
}

extension NativeStrings {
    /// "Look Up “%@”"
    static var lookUpFormat: String { MessagesLabLocalization.string("selection.menu.lookUp", "Look Up “%@”", table: "AppKitNative") }
    static var searchWithGoogle: String { MessagesLabLocalization.string("selection.menu.searchGoogle", "Search With Google", table: "AppKitNative") }
    static var share: String { MessagesLabLocalization.string("selection.menu.share", "Share…", table: "AppKitNative") }
    static var services: String { MessagesLabLocalization.string("selection.menu.services", "Services", table: "AppKitNative") }
    static var speech: String { MessagesLabLocalization.string("selection.menu.speech", "Speech", table: "AppKitNative") }
    static var startSpeaking: String { MessagesLabLocalization.string("selection.menu.startSpeaking", "Start Speaking", table: "AppKitNative") }
    static var stopSpeaking: String { MessagesLabLocalization.string("selection.menu.stopSpeaking", "Stop Speaking", table: "AppKitNative") }
    /// The local person's name in copied text ("Me").
    static var me: String { MessagesLabLocalization.string("selection.me", "Me", table: "AppKitNative") }
}

extension TranscriptDocumentView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) { controller?.selection.copy() }
    /// Real Messages: Cmd-A in the transcript changes nothing (sel-real-real-cmd-a: the clicked
    /// message stays selected and Cmd-C copies it). `--select-all-history` selects the whole
    /// history instead (SELECTION.md, decision).
    @objc override func selectAll(_ sender: Any?) {
        if ProcessInfo.processInfo.arguments.contains("--select-all-history") { controller?.selection.selectAll() }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return controller.map { !$0.selection.isEmpty || $0.selection.selectedKey != nil } ?? false }
        if item.action == #selector(selectAll(_:)) { return true }
        return false
    }
}
