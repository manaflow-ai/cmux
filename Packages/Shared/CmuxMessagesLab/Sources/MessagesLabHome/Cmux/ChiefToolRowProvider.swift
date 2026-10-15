import AppKit

/// The Chief's tool calls as one compact line on its side of the transcript
/// (`ChiefRows.toolKind`, a full-width hosted row with no bubble):
///
///     [terminal]  Ran cmux tree --all  ✓
///     [terminal]  Ran 3 commands  ⟳  ›        (a run; a click lists every call)
///
/// The 12 pt glyph on the bubbles' left edge says what kind of call it was
/// (terminal, document, pencil, magnifying glass, globe), the 11.5 pt text is
/// secondary-label grey with only the command monospaced (one line, middle
/// ellipsis), and the trailing glyph is the state: a 10 pt spinner while
/// running, a tertiary checkmark when done, a red xmark when it failed.
/// A run expands in place (Return or a click; Left and Right on the focused row). References (cmux-design-references):
/// Claude Code web's tool lines (claude/web/web-session-tool-transcript.png),
/// Codex's "Called 4 tools" collapsed runs (codex/web/tools-running-progress.png)
/// and T3 Code's inline command line (t3-code/live/approval-command-and-thread-details.png).
final class ChiefToolRowProvider: TranscriptCustomRowProvider {
    static let shared = ChiefToolRowProvider()

    let kind = ChiefRows.toolKind
    var measuresOffMain: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .fullWidth }

    // Row metrics (points).
    static let lineHeight: CGFloat = 22
    static let callHeight: CGFloat = 20
    static let listBottom: CGFloat = 4

    /// Expanded runs by group id. Read by `measure` on any thread.
    private let lock = NSLock()
    private var expanded: Set<String> = []

    func isExpanded(_ group: String) -> Bool { lock.lock(); defer { lock.unlock() }; return expanded.contains(group) }
    func setExpanded(_ group: String, _ on: Bool) {
        lock.lock()
        if on { expanded.insert(group) } else { expanded.remove(group) }
        lock.unlock()
    }

    static func height(_ tools: ChiefRows.Tools, expanded: Bool) -> CGFloat {
        guard tools.calls.count > 1, expanded else { return lineHeight }
        return lineHeight + CGFloat(tools.calls.count) * callHeight + listBottom
    }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let tools = part.decode(ChiefRows.Tools.self) else { return CGSize(width: maxWidth, height: Self.lineHeight) }
        return CGSize(width: maxWidth, height: Self.height(tools, expanded: isExpanded(tools.group)))
    }

    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }

    func makeView() -> CustomRowPlatformView { ChiefToolRowView() }

    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {
        guard let v = view as? ChiefToolRowView, let tools = part.decode(ChiefRows.Tools.self) else { return }
        v.show(tools, expanded: isExpanded(tools.group), context: context, provider: self)
    }

    func prepareForReuse(_ view: CustomRowPlatformView) { (view as? ChiefToolRowView)?.reset() }

    func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool {
        guard let tools = part.decode(ChiefRows.Tools.self), tools.calls.count > 1 else { return false }
        switch key {
        case .enter: toggle(tools.group, context: context)
        case .right where !isExpanded(tools.group): toggle(tools.group, context: context)
        case .left where isExpanded(tools.group): toggle(tools.group, context: context)
        default: return false
        }
        return true
    }

    func plainText(_ part: CustomPart) -> String? {
        part.decode(ChiefRows.Tools.self).map(ChiefRows.plainText)
    }

    /// Expands or collapses a run: the row re-measures and its height animates (the host's spring).
    func toggle(_ group: String, context: CustomRowContext) {
        setExpanded(group, !isExpanded(group))
        context.actions?.heightDidChange()
    }
}

/// The tool row's view: drawn text and glyphs, a spinner per running call.
final class ChiefToolRowView: NSView {
    private var tools: ChiefRows.Tools?
    private var expanded = false
    private var context: CustomRowContext?
    private weak var provider: ChiefToolRowProvider?
    private var hovering = false
    private var spinners: [NSProgressIndicator] = []
    private var tracking: NSTrackingArea?

    // Geometry inside the full-width column: the glyph on the bubbles' left edge (window x 20).
    static let glyphX: CGFloat = 0
    static let textX: CGFloat = 18
    static let listGlyphX: CGFloat = 18
    static let listTextX: CGFloat = 34
    /// The line never runs wider than a bubble column plus the glyph (a wide pane stays calm).
    static let maxLineWidth: CGFloat = 460

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func reset() {
        tools = nil
        context = nil
        hovering = false
        spinners.forEach { $0.stopAnimation(nil); $0.removeFromSuperview() }
        spinners = []
        drawn = []
        toolTip = nil
    }

    func show(_ tools: ChiefRows.Tools, expanded: Bool, context: CustomRowContext, provider: ChiefToolRowProvider) {
        self.tools = tools
        self.expanded = expanded
        self.context = context
        self.provider = provider
        let summary = ChiefRows.summary(tools)
        setAccessibilityLabel(summary)
        setAccessibilityValue(Self.stateText(tools.state))
        let run = tools.calls.count > 1
        setAccessibilityRole(run ? .button : .staticText)
        if run {
            setAccessibilityExpanded(expanded)
            setAccessibilityHelp(expanded ? CmuxStrings.toolHide : CmuxStrings.toolShowAll)
        }
        setAccessibilityIdentifier("ChiefToolRow")
        // The full list (and each call's detail) in the tooltip; Copy writes the same lines.
        toolTip = tools.calls.map { call in
            [call.title, call.detail].compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        rebuild()
    }

    static func stateText(_ s: ChiefRows.ToolCall.State) -> String {
        switch s {
        case .running: return CmuxStrings.toolStateRunning
        case .done: return CmuxStrings.toolStateDone
        case .failed: return CmuxStrings.toolStateFailed
        }
    }

    // MARK: Text

    private var secondary: NSColor { Fixture.secondaryText }
    /// The done checkmark: quieter than the text (a tertiary label).
    private var tertiary: NSColor { Fixture.secondaryText.withAlphaComponent(0.55) }
    private var codeColor: NSColor { Fixture.incomingText.withAlphaComponent(Fixture.lightAppearance ? 0.78 : 0.72) }
    private static let font = HomeFonts.system(ofSize: 11.5)
    private static let listFont = HomeFonts.system(ofSize: 11)
    private static let code = HomeFonts.monospaced(ofSize: 11)
    private static let listCode = HomeFonts.monospaced(ofSize: 10.5)

    /// One call's line, the command monospaced and middle-truncated to `width`.
    private func line(_ call: ChiefRows.ToolCall, width: CGFloat, list: Bool) -> NSAttributedString {
        let font = list ? Self.listFont : Self.font, mono = list ? Self.listCode : Self.code
        let plainColor = hovering && !list ? Fixture.incomingText : secondary
        let kind = call.kind
        let (plain, code) = kind == .described ? ("", call.title) : kind.split(call.title)
        // "Ran %@": the localized frame around the command (word order is the language's).
        let token = "\u{1}"
        let frame = kind == .command ? (call.state == .running ? CmuxStrings.toolRunning(token) : CmuxStrings.toolRan(token)) : plain + token
        let pieces = frame.components(separatedBy: token)
        let before = pieces.first ?? "", after = pieces.dropFirst().joined(separator: token)
        func build(_ shown: String) -> NSAttributedString {
            let s = NSMutableAttributedString(string: before, attributes: [.font: font, .foregroundColor: plainColor])
            s.append(NSAttributedString(string: shown, attributes: [.font: kind == .described ? font : mono,
                                                                      .foregroundColor: kind == .described ? plainColor : codeColor]))
            s.append(NSAttributedString(string: after, attributes: [.font: font, .foregroundColor: plainColor]))
            return s
        }
        return Self.fitting(code, width: width, build: build)
    }

    /// `build(code)`, or with the code middle-truncated until the line fits `width` (the program
    /// and its last argument stay readable).
    static func fitting(_ code: String, width: CGFloat, build: (String) -> NSAttributedString) -> NSAttributedString {
        let full = build(code)
        guard full.size().width > width, !code.isEmpty else { return full }
        let chars = Array(code)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if build(middle(chars, keep: mid)).size().width <= width { lo = mid } else { hi = mid - 1 }
        }
        return build(middle(chars, keep: lo))
    }

    static func middle(_ chars: [Character], keep: Int) -> String {
        guard keep < chars.count else { return String(chars) }
        guard keep > 1 else { return "…" }
        let head = (keep + 1) / 2, tail = keep - head
        return String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
    }

    private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    // MARK: Layout and drawing

    /// One drawn line: its kind glyph, text, and the trailing glyphs' places.
    private struct Line {
        var kind: ChiefRows.ToolKind
        var text: NSAttributedString
        var glyphX: CGFloat
        var textX: CGFloat
        var midY: CGFloat
        var list: Bool
        /// The state glyph's leading x, nil when the line shows none.
        var stateX: CGFloat?
        var state: ChiefRows.ToolCall.State
        /// The run's chevron's leading x.
        var chevronX: CGFloat?
    }

    private var drawn: [Line] = []

    override func layout() {
        super.layout()
        rebuild()
    }

    /// The lines for the current width, state and hover; spinners follow the running calls.
    private func rebuild() {
        drawn = makeLines()
        let running = drawn.filter { $0.state == .running && $0.stateX != nil }
        while spinners.count < running.count {
            let p = NSProgressIndicator()
            p.style = .spinning
            p.controlSize = .mini
            p.isDisplayedWhenStopped = false
            p.setAccessibilityElement(false)
            addSubview(p)
            spinners.append(p)
        }
        var rest = running[...]
        for p in spinners {
            if let l = rest.popFirst(), let x = l.stateX {
                let d: CGFloat = 10
                p.frame = NSRect(x: x - 0.5, y: (l.midY - d / 2).rounded(), width: d, height: d)
                p.isHidden = false
                p.startAnimation(nil)
            } else {
                p.stopAnimation(nil)
                p.isHidden = true
            }
        }
        needsDisplay = true
    }

    private func makeLines() -> [Line] {
        guard let tools else { return [] }
        let limit = min(bounds.width, Self.maxLineWidth)
        let mid = ChiefToolRowProvider.lineHeight / 2
        let run = tools.calls.count > 1
        func finish(_ l: inout Line, showsState: Bool, chevron: Bool) {
            var x = l.textX + ceil(l.text.size().width) + 6
            if showsState { l.stateX = x; x += l.list ? 13 : 15 }
            if chevron { l.chevronX = x }
        }
        guard run else {
            guard let call = tools.calls.first else { return [] }
            var l = Line(kind: call.kind, text: line(call, width: limit - Self.textX - 22, list: false), glyphX: Self.glyphX,
                         textX: Self.textX, midY: mid, list: false, state: call.state)
            finish(&l, showsState: true, chevron: false)
            return [l]
        }
        let commands = tools.calls.allSatisfy { $0.kind == .command }
        let plainColor = hovering ? Fixture.incomingText : secondary
        let summary = NSAttributedString(string: ChiefRows.summary(tools), attributes: [.font: Self.font, .foregroundColor: plainColor])
        var head = Line(kind: commands ? .command : (tools.calls.first?.kind ?? .command), text: summary, glyphX: Self.glyphX,
                        textX: Self.textX, midY: mid, list: false, state: tools.state)
        // The run's own line shows its state only while a call runs or after one failed.
        finish(&head, showsState: tools.state != .done, chevron: true)
        var out = [head]
        guard expanded else { return out }
        for (i, call) in tools.calls.enumerated() {
            let y = ChiefToolRowProvider.lineHeight + CGFloat(i) * ChiefToolRowProvider.callHeight + ChiefToolRowProvider.callHeight / 2
            var l = Line(kind: call.kind, text: line(call, width: limit - Self.listTextX - 20, list: true), glyphX: Self.listGlyphX,
                         textX: Self.listTextX, midY: y, list: true, state: call.state)
            finish(&l, showsState: true, chevron: false)
            out.append(l)
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        for l in drawn {
            let gSize: CGFloat = l.list ? 10.5 : 12
            if let img = symbol(l.kind.symbol, size: gSize, weight: .medium, color: secondary) {
                draw(img, centeredIn: NSRect(x: l.glyphX, y: l.midY - 7, width: 14, height: 14))
            }
            let ts = l.text.size()
            l.text.draw(at: NSPoint(x: l.textX, y: (l.midY - ts.height / 2).rounded()))
            if let x = l.stateX { drawState(l.state, x: x, midY: l.midY, small: l.list) }
            if let x = l.chevronX,
               let img = symbol(expanded ? "chevron.down" : "chevron.right", size: 8.5, weight: .semibold,
                                color: hovering ? Fixture.incomingText : secondary) {
                draw(img, centeredIn: NSRect(x: x, y: l.midY - 6, width: 10, height: 12))
            }
        }
    }

    /// An image at its own size, centred in `box` (upright in this flipped view).
    private func draw(_ image: NSImage, centeredIn box: NSRect) {
        let s = image.size
        let r = NSRect(x: (box.midX - s.width / 2).rounded(), y: (box.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawState(_ state: ChiefRows.ToolCall.State, x: CGFloat, midY: CGFloat, small: Bool) {
        let image: NSImage?
        switch state {
        case .running: return  // a spinner view (rebuild)
        case .done: image = symbol("checkmark", size: small ? 8.5 : 9, weight: .semibold, color: tertiary)
        case .failed: image = symbol("xmark", size: small ? 8.5 : 9, weight: .bold, color: .systemRed)
        }
        guard let image else { return }
        draw(image, centeredIn: NSRect(x: x, y: midY - 6, width: 12, height: 12))
    }

    // MARK: Mouse

    private var isRun: Bool { (tools?.calls.count ?? 0) > 1 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        guard isRun else { return }
        hovering = true
        rebuild()
    }

    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        rebuild()
    }

    override func resetCursorRects() {
        if isRun { addCursorRect(NSRect(x: 0, y: 0, width: min(bounds.width, Self.maxLineWidth), height: ChiefToolRowProvider.lineHeight), cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        // Only the run's own line toggles; the list under it is for reading (tooltips).
        let p = convert(event.locationInWindow, from: nil)
        guard isRun, p.y <= ChiefToolRowProvider.lineHeight else { return }
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isRun else { return false }
        toggle()
        return true
    }

    private func toggle() {
        guard let tools, let context, let provider else { return }
        provider.toggle(tools.group, context: context)
        // The row took the key focus with the click (CustomRowContainer); the field gets it back.
        let actions = context.actions
        DispatchQueue.main.async { actions?.resignFocus() }
    }
}
