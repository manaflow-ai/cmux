import AppKit

/// The Chief's tool calls as one compact line on its side of the transcript
/// (`ChiefRows.toolKind`, a full-width hosted row with no bubble):
///
///     [terminal]  Ran cmux tree --all  ✓
///     [terminal]  Ran 3 commands  ⟳  ›        (a run; a click lists every call)
///
/// The 12 pt glyph on the bubbles' left edge says what kind of call it was
/// (terminal, document, pencil, magnifying glass, globe), the 11.5 pt text is
/// secondary-label grey with only the command monospaced (one line, cut at a
/// word with a trailing ellipsis), and the trailing glyph is the state: a 10 pt
/// spinner while running, a secondary checkmark when done, a red xmark when it
/// failed ("Failed cmux tree --all ✗"). A call the user allowed on its approval
/// card says so on its own line ("Ran cmux chief dispatch … · Allowed ✓"; the
/// card's receipt is this row), and `cmux chief dispatch` reads as what it did
/// ("Started Codex in “#12: fix login”"). The full command is the tooltip, and
/// the row's menu copies it.
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
final class ChiefToolRowView: ChiefDrawnRowView {
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
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { nil }

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
        let allowed = tools.allowed == true
        setAccessibilityLabel(summary)
        setAccessibilityValue(allowed ? Self.stateText(tools.state) + ", " + CmuxStrings.approvalAllowed : Self.stateText(tools.state))
        let run = tools.calls.count > 1
        setAccessibilityRole(run ? .button : .staticText)
        if run {
            setAccessibilityExpanded(expanded)
            setAccessibilityHelp(expanded ? CmuxStrings.toolHide : CmuxStrings.toolShowAll)
        }
        setAccessibilityIdentifier("ChiefToolRow")
        // The full list (and each call's detail) in the tooltip; Copy writes the same lines.
        let allowedLine: [String] = allowed ? [CmuxStrings.approvalAllowed] : []
        let callLines: [String] = tools.calls.map { call -> String in
            [ChiefRows.displayTitle(call.title), call.detail].compactMap { $0 }.joined(separator: "\n")
        }
        toolTip = (allowedLine + callLines).joined(separator: "\n\n")
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
    /// The done checkmark: the secondary label colour, at least 3:1 against the pane (a 0.55 alpha
    /// tertiary read as nearly invisible, v3f c-turn-done).
    private var doneColor: NSColor { Self.checkColor(secondary: Fixture.secondaryText, background: Fixture.background) }

    /// The least contrast of the done checkmark against the pane (WCAG non-text contrast).
    static let checkMinContrast: CGFloat = 3

    /// `secondary`, moved toward black on a light `background` or white on a dark one until it
    /// has `checkMinContrast` against it. Pure, for tests.
    static func checkColor(secondary: NSColor, background: NSColor) -> NSColor {
        let bg = background.usingColorSpace(.sRGB) ?? NSColor(white: 0.5, alpha: 1)
        let base = secondary.usingColorSpace(.sRGB) ?? NSColor(white: 0.5, alpha: 1)
        let toward: NSColor = luminance(bg) > 0.5 ? .black : .white
        var color = base.withAlphaComponent(1)
        var step: CGFloat = 0
        while contrast(color, bg) < checkMinContrast, step < 1 {
            step = min(1, step + 0.05)
            color = base.withAlphaComponent(1).blended(withFraction: step, of: toward) ?? toward
        }
        return color
    }

    /// WCAG relative luminance of an sRGB colour (alpha ignored).
    static func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB) ?? NSColor(white: 0.5, alpha: 1)
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r: CGFloat = 0.2126 * lin(s.redComponent)
        let g: CGFloat = 0.7152 * lin(s.greenComponent)
        let b: CGFloat = 0.0722 * lin(s.blueComponent)
        return r + g + b
    }

    /// WCAG contrast ratio of two colours.
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    private var codeColor: NSColor { Fixture.incomingText.withAlphaComponent(Fixture.lightAppearance ? 0.78 : 0.72) }
    private static let font = HomeFonts.system(ofSize: 11.5)
    private static let listFont = HomeFonts.system(ofSize: 11)
    private static let code = HomeFonts.monospaced(ofSize: 11)
    private static let listCode = HomeFonts.monospaced(ofSize: 10.5)

    /// One call's line, the command monospaced and cut at a word to fit `width`; `allowed` adds
    /// " · Allowed" (the approval the call ran under).
    private func line(_ call: ChiefRows.ToolCall, width: CGFloat, list: Bool, allowed: Bool = false) -> NSAttributedString {
        let font = list ? Self.listFont : Self.font, mono = list ? Self.listCode : Self.code
        let plainColor = hovering && !list ? Fixture.incomingText : secondary
        // Expanded runs are a history list. The parent already says “Ran N
        // commands”; repeating “Ran” on every child makes the hierarchy read
        // like duplicated log entries, so children show only the subject.
        if list {
            let subject = ChiefRows.subject(call)
            let subjectFont = call.kind == .command && call.humanTitle == nil ? mono : font
            return Self.fitting(subject, width: width) { shown in
                NSAttributedString(string: shown, attributes: [.font: subjectFont, .foregroundColor: plainColor])
            }
        }
        let tag = allowed ? " · " + CmuxStrings.approvalAllowed : ""
        if let human = call.humanTitle {
            return Self.fitting(human, width: width) { shown in
                NSAttributedString(string: shown + tag, attributes: [.font: font, .foregroundColor: plainColor])
            }
        }
        let kind = call.kind
        let (plain, code) = kind == .described ? ("", call.title) : kind.split(call.title)
        // "Ran %@": the localized frame around the command (word order is the language's).
        let token = "\u{1}"
        let frame = kind == .command ? ChiefRows.commandFrame(call.state)(token) : kind.localizedFrame(token) ?? plain + token
        let pieces = frame.components(separatedBy: token)
        let before = pieces.first ?? "", after = pieces.dropFirst().joined(separator: token) + tag
        func build(_ shown: String) -> NSAttributedString {
            let s = NSMutableAttributedString(string: before, attributes: [.font: font, .foregroundColor: plainColor])
            s.append(NSAttributedString(string: shown, attributes: [.font: kind == .described ? font : mono,
                                                                      .foregroundColor: kind == .described ? plainColor : codeColor]))
            s.append(NSAttributedString(string: after, attributes: [.font: font, .foregroundColor: plainColor]))
            return s
        }
        return Self.fitting(code, width: width, build: build)
    }

    /// `build(code)`, or with the code cut at the end of a word and an ellipsis, as long as the
    /// line fits `width` (never inside a word: "cmux chief dispatch --agent …", not "code…t").
    static func fitting(_ code: String, width: CGFloat, build: (String) -> NSAttributedString) -> NSAttributedString {
        let full = build(code)
        guard full.size().width > width, !code.isEmpty else { return full }
        let chars = Array(code)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if build(truncated(chars, keep: mid)).size().width <= width { lo = mid } else { hi = mid - 1 }
        }
        return build(truncated(chars, keep: lo))
    }

    /// The first `keep` characters cut back to the last whole word, then "…". A first word longer
    /// than `keep` is cut inside (nothing else would fit).
    static func truncated(_ chars: [Character], keep: Int) -> String {
        guard keep < chars.count else { return String(chars) }
        let head = String(chars.prefix(keep))
        var cut = head
        if chars.dropFirst(keep).first != " ", let space = head.range(of: " ", options: .backwards) {
            cut = String(head.prefix(upTo: space.lowerBound))
        }
        while cut.last == " " { cut.removeLast() }
        return (cut.isEmpty ? head : cut) + "…"
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
            var l = Line(kind: call.kind, text: line(call, width: limit - Self.textX - 22, list: false, allowed: tools.allowed == true),
                         glyphX: Self.glyphX,
                         textX: Self.textX, midY: mid, list: false, state: call.state)
            finish(&l, showsState: true, chevron: false)
            return [l]
        }
        let commands = tools.calls.allSatisfy { $0.kind == .command }
        let plainColor = hovering ? Fixture.incomingText : secondary
        let tag = tools.allowed == true ? " · " + CmuxStrings.approvalAllowed : ""
        let summary = Self.fitting(ChiefRows.summary(tools), width: limit - Self.textX - 34) { shown in
            NSAttributedString(string: shown + tag, attributes: [.font: Self.font, .foregroundColor: plainColor])
        }
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
        case .done: image = symbol("checkmark", size: small ? 9 : 10, weight: .bold, color: doneColor)
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

    /// Copy: the commands as run (one per line), never the shortened line.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tools, !tools.calls.isEmpty else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: Strings.menuCopy, action: #selector(copyCommands(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        // A failed call: its detail (a run lists every call with its output in the tooltip) and Try Again,
        // which sends the last message again (refused while a turn runs).
        if tools.state == .failed {
            if tools.calls.count > 1, !expanded {
                let show = NSMenuItem(title: CmuxStrings.toolShowAll, action: #selector(showAll(_:)), keyEquivalent: "")
                show.target = self
                menu.addItem(show)
            }
            let retry = NSMenuItem(title: CmuxStrings.failureTryAgain, action: #selector(tryAgain(_:)), keyEquivalent: "")
            retry.target = self
            retry.toolTip = CmuxStrings.failureTryAgainHelp
            retry.isEnabled = ChiefRows.intents(of: self) != nil
            menu.addItem(retry)
        }
        return menu
    }

    @objc private func showAll(_ sender: NSMenuItem) { if !expanded { toggle() } }

    @objc private func tryAgain(_ sender: NSMenuItem) {
        ChiefRows.intents(of: self)?.retryLastTurn { _ in }
    }

    @objc private func copyCommands(_ sender: NSMenuItem) {
        guard let tools else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(tools.calls.map(\.title).joined(separator: "\n"), forType: .string)
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
