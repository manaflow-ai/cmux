import AppKit
import CmuxHomeCore

/// The owner's system rows, both stored as a `MessagePart.work` the Chief posts (CmuxChief's
/// `ChiefConversationOwner.failureSessionPrefix` and `memorySessionPrefix`, `ChiefRows.failurePrefix`
/// and `memoryPrefix` here):
///
/// - A failed turn: a full-width row on the Chief's side, not a bubble: a red
///   exclamationmark.circle, the owner's first-person text ("I couldn't finish: the cmux
///   control socket closed before the tree came back.") and, while it is the newest
///   message, a "Try Again" button that runs the last message again
///   (`ChatIntents.retryLastTurn`).
/// - A saved memory note: a centred 11 pt secondary line, "Chief will remember: <note> ·
///   Undo", whether it was saved in a turn (the owner posts it after the turn's last message)
///   or outside one (one event, one wording), Undo in the accent (`ChatIntents.undoMemory`).
///   After Undo it reads "Removed from memory: <note>". It scrolls with the transcript, so it
///   never sits over another line.
/// - A stopped turn: the same centred 11 pt secondary line, "Stopped" (the owner's localized
///   title of a `chief.stopped:` part), where the Chief's reply ends after the user's Stop.
///
/// References (cmux-design-references): apps/t3-code/web/computer-use-log.png (a failed request
/// marked and actionable in the work log), topics/status-and-progress.md (one status line at a
/// time) and apps/aside/web/memory-file-browser.jpg (a saved note confirmed in place).
extension ChiefRows {
    /// A failed turn's row.
    struct Failure: Codable, Hashable {
        var id: String
        var text: String
        var retry: Bool
    }

    /// A saved note's row.
    struct Memory: Codable, Hashable {
        /// The note's id (`m-…`, what Undo forgets).
        var fact: String
        var note: String
        /// Saved while the Chief worked on this conversation.
        var duringTurn: Bool
        /// Undo forgot it.
        var forgotten: Bool
    }

    /// A stopped turn's row (its text is the owner's localized title).
    struct Stopped: Codable, Hashable {
        var id: String
        var text: String
    }

    /// A stopped turn's system row (CmuxChief's `ChiefConversationOwner.stoppedSessionPrefix`, the same id).
    static let stoppedKind = "cmux.chief.stopped"
    static let stoppedPrefix = "chief.stopped:"

    /// A stopped turn's work part.
    static func isStopped(_ work: WorkRef) -> Bool { work.host == nil && work.session.hasPrefix(stoppedPrefix) }

    /// The memory part's session: `chief.memory:t:<id>` (in a turn) or `chief.memory:s:<id>`.
    static func memory(_ work: WorkRef) -> Memory? {
        guard isMemory(work) else { return nil }
        let rest = work.session.dropFirst(memoryPrefix.count)
        let duringTurn = rest.hasPrefix("t:")
        guard duringTurn || rest.hasPrefix("s:") else { return nil }
        return Memory(fact: String(rest.dropFirst(2)), note: work.title, duringTurn: duringTurn, forgotten: work.status == .failed)
    }

    /// "Chief will remember: <note>" whether the note was saved in a turn or outside one (one event,
    /// one wording); "Removed from memory: <note>" after Undo.
    static func memoryText(_ m: Memory) -> String {
        m.forgotten ? CmuxStrings.memoryForgotten(m.note) : CmuxStrings.memoryWillRemember(m.note)
    }

    /// The row of a system work part; nil for any other work part.
    static func noticePart(_ work: WorkRef, retry: Bool) -> CustomPart? {
        if ChiefRows.isFailure(work) {
            return ChiefRows.part(kind: ChiefRows.failureKind, ChiefRows.Failure(id: work.session, text: work.title, retry: retry))
        }
        if let memory = ChiefRows.memory(work) { return ChiefRows.part(kind: ChiefRows.memoryKind, memory) }
        if ChiefRows.isStopped(work) {
            return ChiefRows.part(kind: ChiefRows.stoppedKind, ChiefRows.Stopped(id: work.session, text: work.title))
        }
        return nil
    }

    /// The pane's intents (the HomeStore adapter): row views live in their HostView's overlay.
    @MainActor static func intents(of view: NSView) -> ChatIntents? {
        var v: NSView? = view
        while let current = v {
            if let host = current as? HostView { return host.controller?.intents }
            v = current.superview
        }
        return nil
    }
}

// MARK: Failure row

final class ChiefFailureRowProvider: TranscriptCustomRowProvider {
    static let shared = ChiefFailureRowProvider()

    let kind = ChiefRows.failureKind
    var measuresOffMain: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .fullWidth }

    static let font = HomeFonts.system(ofSize: 13)
    static let padY: CGFloat = 3
    static let buttonGap: CGFloat = 6
    static let buttonHeight: CGFloat = 24

    static func text(_ s: String, color: NSColor? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        if let color { attrs[.foregroundColor] = color }
        return NSAttributedString(string: s, attributes: attrs)
    }

    /// The text's width in a column `maxWidth` wide (the tool rows' column).
    static func textWidth(_ maxWidth: CGFloat) -> CGFloat {
        max(40, min(maxWidth, ChiefToolRowView.maxLineWidth) - ChiefToolRowView.textX)
    }

    static func textHeight(_ f: ChiefRows.Failure, maxWidth: CGFloat) -> CGFloat {
        ceil(text(f.text).boundingRect(with: CGSize(width: textWidth(maxWidth), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    static func size(_ f: ChiefRows.Failure, maxWidth: CGFloat) -> CGSize {
        let button = f.retry ? buttonGap + buttonHeight : 0
        return CGSize(width: maxWidth, height: padY + max(16, textHeight(f, maxWidth: maxWidth)) + button + padY)
    }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let f = part.decode(ChiefRows.Failure.self) else { return CGSize(width: maxWidth, height: 22) }
        return Self.size(f, maxWidth: maxWidth)
    }

    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }
    func makeView() -> CustomRowPlatformView { ChiefFailureRowView() }

    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {
        guard let v = view as? ChiefFailureRowView, let f = part.decode(ChiefRows.Failure.self) else { return }
        v.show(f)
    }

    func prepareForReuse(_ view: CustomRowPlatformView) { (view as? ChiefFailureRowView)?.reset() }

    func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool {
        guard key == .enter, let v = view as? ChiefFailureRowView, part.decode(ChiefRows.Failure.self)?.retry == true else { return false }
        v.tryAgain()
        return true
    }

    func plainText(_ part: CustomPart) -> String? { part.decode(ChiefRows.Failure.self)?.text }
}

/// A hosted row's view that draws itself (`draw(_:)`, redrawn only on `needsDisplay`): it draws
/// again whenever what it shows could have gone. cmux-classic: after a reflow the failed turn's row
/// was laid out (38 pt) but drawn blank: its container came back at a new size or into the window
/// again (CustomRowsHost reuse) and nothing asked the view to draw.
class ChiefDrawnRowView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    /// Redraws asked for (tests).
    private(set) var redrawRequests = 0
    /// Draws again at the next display.
    func requestRedraw() {
        redrawRequests += 1
        needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { requestRedraw() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { requestRedraw() }
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        requestRedraw()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        requestRedraw()
    }
}

/// The failure row's view: the red glyph, the drawn text, the Try Again button.
final class ChiefFailureRowView: ChiefDrawnRowView {
    private var failure: ChiefRows.Failure?
    private let button = ChiefOptionButton(option: CmuxStrings.failureTryAgain, style: .quiet)
    /// The failure whose Try Again went out, waiting for the next turn.
    private var sent: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.target = self
        button.action = #selector(tryAgainClicked)
        button.toolTip = CmuxStrings.failureTryAgainHelp
        button.setAccessibilityHelp(CmuxStrings.failureTryAgainHelp)
        button.setAccessibilityIdentifier("ChiefFailureTryAgain")
        addSubview(button)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription(CmuxStrings.failureRole)
        setAccessibilityIdentifier("ChiefFailureRow")
    }
    required init?(coder: NSCoder) { nil }

    func reset() {
        failure = nil
        sent = nil
        requestRedraw()
    }

    func show(_ f: ChiefRows.Failure) {
        if failure?.id != f.id { sent = nil }
        failure = f
        button.isHidden = !f.retry
        button.isEnabled = sent == nil
        button.restyle()
        setAccessibilityLabel(f.text)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let f = failure else { return }
        let p = ChiefFailureRowProvider.self
        let w = ceil(button.intrinsicContentSize.width) + 24
        let y = p.padY + max(16, p.textHeight(f, maxWidth: bounds.width)) + p.buttonGap
        button.frame = NSRect(x: ChiefToolRowView.textX, y: y, width: max(72, w), height: p.buttonHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let f = failure else { return }
        let p = ChiefFailureRowProvider.self
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        let lineHeight = ceil(p.font.ascender - p.font.descender + p.font.leading)
        if let img = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let s = img.size
            img.draw(in: NSRect(x: (ChiefToolRowView.glyphX + (14 - s.width) / 2).rounded(), y: (p.padY + (lineHeight - s.height) / 2).rounded(),
                                width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let width = p.textWidth(bounds.width)
        p.text(f.text, color: Fixture.secondaryText).draw(with: NSRect(x: ChiefToolRowView.textX, y: p.padY, width: width,
                                                                        height: p.textHeight(f, maxWidth: bounds.width)),
                                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    @objc private func tryAgainClicked() { tryAgain() }

    /// Runs the last message again (the button, or Return while the row has the focus).
    func tryAgain() {
        guard let f = failure, f.retry, sent == nil, let intents = ChiefRows.intents(of: self) else { return }
        sent = f.id
        button.isEnabled = false
        intents.retryLastTurn { [weak self] ok in
            // Refused (a turn already runs, nothing to resend): the button comes back.
            guard let self, !ok, self.sent == f.id else { return }
            self.sent = nil
            self.button.isEnabled = true
        }
    }
}

// MARK: Memory row

final class ChiefMemoryRowProvider: TranscriptCustomRowProvider {
    static let shared = ChiefMemoryRowProvider()

    let kind = ChiefRows.memoryKind
    var measuresOffMain: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .fullWidth }

    static let height: CGFloat = 22
    static let font = HomeFonts.system(ofSize: 11)
    static let undoFont = HomeFonts.system(ofSize: 11, weight: .semibold)

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { CGSize(width: maxWidth, height: Self.height) }
    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }
    func makeView() -> CustomRowPlatformView { ChiefMemoryRowView() }

    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {
        guard let v = view as? ChiefMemoryRowView, let m = part.decode(ChiefRows.Memory.self) else { return }
        v.show(m)
    }

    func prepareForReuse(_ view: CustomRowPlatformView) { (view as? ChiefMemoryRowView)?.reset() }

    func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool {
        guard key == .enter, let v = view as? ChiefMemoryRowView, part.decode(ChiefRows.Memory.self)?.forgotten == false else { return false }
        v.undo()
        return true
    }

    func plainText(_ part: CustomPart) -> String? { part.decode(ChiefRows.Memory.self).map(ChiefRows.memoryText) }
}

/// The memory row's view: the centred line and its Undo link (a borderless button in the accent).
final class ChiefMemoryRowView: ChiefDrawnRowView {
    private var memory: ChiefRows.Memory?
    private let undoButton = NSButton(title: "", target: nil, action: nil)
    private var sent = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        undoButton.isBordered = false
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        undoButton.toolTip = CmuxStrings.memoryUndoHelp
        undoButton.setAccessibilityHelp(CmuxStrings.memoryUndoHelp)
        undoButton.setAccessibilityIdentifier("ChiefMemoryUndo")
        addSubview(undoButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("ChiefMemoryRow")
    }
    required init?(coder: NSCoder) { nil }

    func reset() {
        memory = nil
        sent = false
        requestRedraw()
    }

    func show(_ m: ChiefRows.Memory) {
        if memory?.fact != m.fact || m.forgotten { sent = false }
        memory = m
        undoButton.isHidden = m.forgotten
        undoButton.isEnabled = !sent
        undoButton.attributedTitle = NSAttributedString(string: CmuxStrings.memoryUndo, attributes: [
            .font: ChiefMemoryRowProvider.undoFont, .foregroundColor: Fixture.outgoing,
        ])
        let text = ChiefRows.memoryText(m)
        setAccessibilityLabel(text)
        toolTip = m.note
        needsLayout = true
        needsDisplay = true
    }

    /// The line's text, cut at a word to leave room for Undo.
    private func line(width: CGFloat) -> NSAttributedString {
        guard let m = memory else { return NSAttributedString() }
        let tail = m.forgotten ? "" : " · "
        let attrs: [NSAttributedString.Key: Any] = [.font: ChiefMemoryRowProvider.font, .foregroundColor: Fixture.secondaryText]
        return ChiefToolRowView.fitting(ChiefRows.memoryText(m), width: width) { NSAttributedString(string: $0 + tail, attributes: attrs) }
    }

    private var undoWidth: CGFloat { undoButton.isHidden ? 0 : ceil(undoButton.attributedTitle.size().width) + 4 }

    override func layout() {
        super.layout()
        let text = line(width: max(40, bounds.width - 32 - undoWidth))
        let total = ceil(text.size().width) + undoWidth
        let x = ((bounds.width - total) / 2).rounded()
        undoButton.frame = NSRect(x: x + ceil(text.size().width), y: 2, width: undoWidth, height: bounds.height - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = line(width: max(40, bounds.width - 32 - undoWidth))
        let size = text.size()
        let total = ceil(size.width) + undoWidth
        text.draw(at: NSPoint(x: ((bounds.width - total) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }

    @objc private func undoClicked() { undo() }

    /// Forgets the note (the link, or Return while the row has the focus).
    func undo() {
        guard let m = memory, !m.forgotten, !sent, let intents = ChiefRows.intents(of: self) else { return }
        sent = true
        undoButton.isEnabled = false
        intents.undoMemory(fact: m.fact) { [weak self] ok in
            guard let self, !ok, self.memory?.fact == m.fact else { return }
            self.sent = false
            self.undoButton.isEnabled = true
        }
    }
}

// MARK: Stopped row

final class ChiefStoppedRowProvider: TranscriptCustomRowProvider {
    static let shared = ChiefStoppedRowProvider()

    let kind = ChiefRows.stoppedKind
    var measuresOffMain: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .fullWidth }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { CGSize(width: maxWidth, height: ChiefMemoryRowProvider.height) }
    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }
    func makeView() -> CustomRowPlatformView { ChiefStoppedRowView() }

    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {
        guard let v = view as? ChiefStoppedRowView, let s = part.decode(ChiefRows.Stopped.self) else { return }
        v.show(s.text)
    }

    func prepareForReuse(_ view: CustomRowPlatformView) { (view as? ChiefStoppedRowView)?.show("") }

    func handleKey(_ key: CustomRowKey, view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) -> Bool { false }

    func plainText(_ part: CustomPart) -> String? { part.decode(ChiefRows.Stopped.self)?.text }
}

/// The stopped row's view: one centred secondary line, like the memory row without its link.
final class ChiefStoppedRowView: ChiefDrawnRowView {
    private var text = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("ChiefStoppedRow")
    }
    required init?(coder: NSCoder) { nil }

    func show(_ text: String) {
        self.text = text
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let line = NSAttributedString(string: text, attributes: [
            .font: ChiefMemoryRowProvider.font, .foregroundColor: Fixture.secondaryText,
        ])
        let size = line.size()
        line.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }
}
