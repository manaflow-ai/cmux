import CmuxAgentQuestion
import CoreGraphics
import Foundation
import os

/// cmux: the Chief's permission approval in Home, as a drawn custom row (CustomRows.swift,
/// `Part.custom` of kind ``kind``) with the question's two buttons.
///
/// The Chief posts the approval as a `question` part of harness `chief` with a `permission`
/// (optchat-chief `approval.rs` `card()`): one item `approval` with the header "Approval", the
/// headline as its prompt, and the options `allow` ("Allow once", the reason as its detail and the
/// tool's arguments as its monospace preview) and `deny`. `HomeMapping.part` maps that part here
/// while the provider is registered; any other question stays text.
///
/// A pending card draws the whole question as the agent pane's question card does
/// (CmuxNextAgentQuestion's `AgentQuestionCardStyle`, the web `QuestionCard`): the header chip, the
/// headline (its `code` spans monospaced), the reason in the secondary color, the arguments in a
/// rounded monospace block of at most ``previewMaxLines`` lines, then Deny and the primary Allow
/// once at the right, labelled from the part. An answered or cancelled card is one line.
///
/// A click on a button (``ChatController/clicked(_:)`` in the transcript, `hostControl` in a thread
/// view) goes to ``click(_:ref:allow:)``: the projection that shows the message answers acpmux as
/// the person, then the part (`question.answer`). Every click that cannot start a decision says why
/// on the card; none is dropped silently.
///
/// While a decision is in flight its buttons draw disabled and take no click; a refused decision
/// shows its error under the buttons, which take clicks again (plans/cmux-next/agent-questions.md
/// §6, §7). That state is this Mac's, not the conversation's: it lives in ``local`` by
/// session and permission, and the mapping copies it into the payload, so a rebuild keeps it.
/// The pointer's hover and press are the pane's own: the controller writes them into the shown
/// part only (``Payload/pointer``), and a rebuild drops them until the pointer moves again.
final class HomeApprovalRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.approval"
    /// The item and options the Chief's approval question carries (optchat-chief's contract).
    static let item = "approval"
    static let allowOption = "allow"
    static let denyOption = "deny"

    // MARK: Metrics (AgentQuestionCardStyle at scale 1, inside a bubble's padding)

    /// The widest card (a long command wraps inside it).
    static let maxWidth: CGFloat = 420
    static let padY: CGFloat = 10
    static let chipHeight: CGFloat = 18
    static let chipInset: CGFloat = 7
    static let chipRadius: CGFloat = 6
    /// Under the header chip.
    static let headerGap: CGFloat = 6
    /// Between the headline and the reason.
    static let reasonGap: CGFloat = 4
    /// Before the arguments block and the buttons.
    static let sectionGap: CGFloat = 10
    static let previewInset: CGFloat = 8
    static let previewRadius: CGFloat = 8
    static let previewMaxLines = 8
    static let previewLineHeight: CGFloat = 14
    static let reasonMaxLines = 3
    static let reasonLineHeight: CGFloat = 15
    static let buttonHeight: CGFloat = 26
    static let buttonInset: CGFloat = 12
    static let buttonMinWidth: CGFloat = 64
    static let buttonGap: CGFloat = 8
    static let buttonRadius: CGFloat = 8
    /// The error or note under the buttons.
    static let statusGap: CGFloat = 6
    static let statusMaxLines = 3
    static let statusLineHeight: CGFloat = 15
    /// A prompt longer than this is cut (the whole request stays in the agent tab).
    static let maxPrompt = 1_200
    static let maxReason = 400
    /// The arguments kept in the payload: more than the block's lines show.
    static let maxPreview = 2_000
    static let maxLabel = 40

    static let chipFont = HomeFonts.system(ofSize: 11, weight: .semibold)
    static let reasonFont = HomeFonts.system(ofSize: 12)
    static let previewFont = HomeFonts.monospaced(ofSize: 11)
    static let buttonFont = HomeFonts.system(ofSize: 12, weight: .semibold)
    static let statusFont = HomeFonts.system(ofSize: 12)
    static let summaryFont = HomeFonts.system(ofSize: 12, weight: .semibold)

    /// The one provider (registered once per process, as the diagram provider).
    static let shared = HomeApprovalRowProvider()

    /// Where the card stands, as the payload carries it.
    enum Status: String, Codable {
        case pending, allowed, denied, skipped
    }

    /// The pointer on a button of the shown card (the pane's hover or press).
    struct Pointer: Codable, Equatable {
        /// On Allow (true) or Deny.
        var allow: Bool
        var pressed = false
    }

    struct Payload: Codable, Equatable {
        var session: String
        var permission: String
        /// The item's header ("Approval"), drawn as a chip.
        var header: String?
        /// The headline; `code` spans draw monospaced.
        var prompt: String
        /// Allow's detail: why the Chief asks.
        var reason: String?
        /// Allow's preview: the tool's arguments.
        var preview: String?
        var allowLabel: String
        var denyLabel: String
        var status: Status
        /// The device that answered (a paired iPhone), nil for this Mac or unknown.
        var device: String?
        /// This Mac's decision is in flight (the buttons draw disabled).
        var busy = false
        /// This Mac's last decision was refused, or a click could not start one: why.
        var error: String?
        /// This Mac's decision landed in acpmux but not on the card ("Allowed; the card was not updated").
        var note: String?
        /// The pointer's hover or press (this pane only).
        var pointer: Pointer?

        init(session: String, permission: String, header: String? = nil, prompt: String, reason: String? = nil,
             preview: String? = nil, allowLabel: String = CmuxStrings.approvalAllow, denyLabel: String = CmuxStrings.approvalDeny,
             status: Status) {
            self.session = session
            self.permission = permission
            self.header = header
            self.prompt = prompt
            self.reason = reason
            self.preview = preview
            self.allowLabel = allowLabel
            self.denyLabel = denyLabel
            self.status = status
        }

        /// The buttons take a click.
        var takesClicks: Bool { status == .pending && !busy }
    }

    /// This Mac's state of one approval (`local`).
    struct Local: Equatable {
        var busy = false
        var error: String?
        var note: String?
    }

    // Lock carve-out: the mapping reads it on the loader queue and the row bitmap threads
    // (CustomRows.swift); the map is a tiny critical section.
    private let locals = OSAllocatedUnfairLock<[String: Local]>(initialState: [:])
    /// The projections that may own a clicked card (main thread).
    private let owners = NSHashTable<HomeProjection>.weakObjects()

    /// The registered provider (nil: approvals stay text).
    static var installed: HomeApprovalRowProvider? { CustomRows.provider(kind) as? HomeApprovalRowProvider }

    /// Registers the provider once and lets `projection` answer its cards' clicks.
    @MainActor
    static func install(for projection: HomeProjection) {
        if installed !== shared { CustomRows.register(shared) }
        shared.owners.add(projection)
    }

    static func key(session: String, permission: String) -> String { session + "\u{0}" + permission }
    static func key(_ p: Payload) -> String { key(session: p.session, permission: p.permission) }

    func local(_ key: String) -> Local { locals.withLock { $0[key] } ?? Local() }

    func setLocal(_ key: String, _ value: Local) {
        locals.withLock { map in
            if value == Local() { map[key] = nil } else { map[key] = value }
        }
    }

    /// The card for a Chief approval question, or nil for any other question.
    func part(_ question: AgentQuestion) -> Part? {
        guard question.source.harness == .chief, let permission = question.source.permission,
              let item = question.items.first(where: { $0.id == Self.item }),
              let allow = item.options.first(where: { $0.id == Self.allowOption }),
              let deny = item.options.first(where: { $0.id == Self.denyOption })
        else { return nil }
        func label(_ option: AgentQuestion.Option, _ fallback: String) -> String {
            let text = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallback : String(text.prefix(Self.maxLabel))
        }
        func nonEmpty(_ text: String?, _ max: Int) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return String(text.prefix(max))
        }
        var payload = Payload(session: question.source.session, permission: permission,
                              header: nonEmpty(item.header, Self.maxLabel),
                              prompt: String(item.prompt.prefix(Self.maxPrompt)),
                              reason: nonEmpty(allow.detail, Self.maxReason),
                              preview: nonEmpty(allow.preview?.text, Self.maxPreview),
                              allowLabel: label(allow, CmuxStrings.approvalAllow), denyLabel: label(deny, CmuxStrings.approvalDeny),
                              status: .pending)
        switch question.state {
        case .pending:
            let mine = local(Self.key(payload))
            payload.busy = mine.busy
            payload.error = mine.error
            payload.note = mine.note
        case .cancelled:
            payload.status = .skipped
        case .answered(let answer):
            let chosen = answer.selections[Self.item]?.optionIDs ?? []
            payload.status = chosen.contains(Self.allowOption) ? .allowed : .denied
            payload.device = answer.respondent?.device
        }
        return Self.custom(payload).map { Part.custom($0) }
    }

    static func payload(_ part: CustomPart) -> Payload? { part.decode(Payload.self) }

    /// `payload` as the row's part (nil only when it does not encode).
    static func custom(_ payload: Payload) -> CustomPart? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return CustomPart(kind: kind, version: version(data), payload: data)
    }

    /// A stable version per payload (FNV-1a): the measure cache and the row bitmaps key on it.
    static func version(_ data: Data) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in data { hash = (hash ^ UInt32(truncatingIfNeeded: byte)) &* 16_777_619 }
        return Int(truncatingIfNeeded: hash & 0x7fff_ffff)
    }

    // MARK: Text

    /// The prompt without its code fences, and a run per code span (CommonMark code spans: a run
    /// of n backticks up to the next run of exactly n; one space inside each fence is dropped
    /// when both are there). Unmatched backticks stay as text.
    static func codeSpans(_ text: String) -> (text: String, code: [NSRange]) {
        let chars = Array(text)
        var out = ""
        var code: [NSRange] = []
        var i = 0
        func ticks(at j: Int) -> Int {
            var n = 0
            while chars[checked: j + n] == "`" { n += 1 }
            return n
        }
        func slice(_ from: Int, _ count: Int) -> String { String(chars.dropFirst(from).prefix(max(0, count))) }
        while let c = chars[checked: i] {
            guard c == "`" else { out.append(c); i += 1; continue }
            let n = ticks(at: i)
            var j = i + n
            var close: Int?
            while let d = chars[checked: j] {
                if d == "`" {
                    let m = ticks(at: j)
                    if m == n { close = j; break }
                    j += m
                } else { j += 1 }
            }
            guard let end = close else {
                out.append(slice(i, n))
                i += n
                continue
            }
            var inner = slice(i + n, end - (i + n))
            if inner.count >= 2, inner.first == " ", inner.last == " ", inner.contains(where: { $0 != " " }) {
                inner = String(inner.dropFirst().dropLast())
            }
            let start = (out as NSString).length
            out += inner
            let length = (out as NSString).length - start
            if length > 0 { code.append(NSRange(location: start, length: length)) }
            i = end + n
        }
        return (out, code)
    }

    /// The headline as the card draws it: bold, its code spans monospaced.
    static func promptLayout(_ prompt: String, width: CGFloat) -> TextLayout {
        let (text, code) = codeSpans(prompt)
        let length = (text as NSString).length
        var runs = [TextRun(start: 0, length: length, style: ["bold"])]
        runs += code.map { TextRun(start: $0.location, length: $0.length, style: ["code"]) }
        return TextLayout.make(text, runs: runs, maxWidth: width)
    }

    /// `text` wrapped to `width` in `font`, at most `maxLines` lines; a cut text's last line ends
    /// with "…".
    static func wrap(_ text: String, font: UIFont, width: CGFloat, maxLines: Int) -> [String] {
        let layout = TextLayout.make(text, runs: [], maxWidth: width, font: font)
        let ns = text as NSString
        var lines = layout.lines.prefix(maxLines).map { line -> String in
            guard let r = TextLayout.range(line.range.location, line.range.length, in: ns.length) else { return "" }
            return ns.substring(with: r).trimmingCharacters(in: .newlines)
        }
        if layout.lines.count > maxLines, let last = lines.popLast() {
            lines.append(fit(last + "\u{2026}", font: font, width: width))
        }
        return Array(lines)
    }

    /// `text` on one line of `width`: cut with a trailing "…" when it does not fit.
    static func fit(_ text: String, font: UIFont, width: CGFloat) -> String {
        guard TextDraw.width(text, font: font) > width else { return text }
        var s = Substring(text.hasSuffix("\u{2026}") ? String(text.dropLast()) : text)
        while !s.isEmpty, TextDraw.width(s.trimmingCharacters(in: .whitespaces) + "\u{2026}", font: font) > width { s = s.dropLast() }
        return s.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The baseline of a line of `font` in a slot of `height` at `top`.
    static func baseline(top: CGFloat, height: CGFloat, font: UIFont) -> CGFloat {
        (top + (height - (font.ascender - font.descender)) / 2 + font.ascender).rounded()
    }

    // MARK: Layout (one function for measure, draw and the click)

    struct Line: Equatable {
        var text: String
        var x: CGFloat
        var baseline: CGFloat
    }

    struct Layout {
        var size: CGSize
        /// The header chip (pending, with a header).
        var chip: CGRect?
        /// The headline (pending) and the top of its first line.
        var prompt: TextLayout?
        var promptTop: CGFloat = 0
        var reason: [Line] = []
        /// The arguments block and its lines (pending, with arguments).
        var preview: CGRect?
        var previewLines: [Line] = []
        /// The buttons (pending only), in the body's coordinates (y down).
        var allow: CGRect?
        var deny: CGRect?
        /// The error or note under the buttons (pending).
        var lines: [Line] = []
        /// The one line of an answered or cancelled card: its status, then the headline.
        var summary: (status: Line, rest: Line?)?
    }

    static func layout(_ p: Payload, width: CGFloat) -> Layout {
        p.status == .pending ? pendingLayout(p, width: width) : summaryLayout(p, width: width)
    }

    private static func pendingLayout(_ p: Payload, width: CGFloat) -> Layout {
        let w = min(width, maxWidth)
        let padX = Fixture.bubblePadX
        let room = max(1, w - 2 * padX)
        var out = Layout(size: .zero)
        var y = padY
        if let header = p.header {
            out.chip = CGRect(x: padX, y: y, width: min(TextDraw.width(header, font: chipFont) + 2 * chipInset, room).rounded(.up),
                              height: chipHeight)
            y += chipHeight + headerGap
        }
        let prompt = promptLayout(p.prompt, width: room)
        out.prompt = prompt
        out.promptTop = y
        y += prompt.textHeight(hard: Fixture.lineHeight)
        if let reason = p.reason {
            y += reasonGap
            for text in wrap(reason, font: reasonFont, width: room, maxLines: reasonMaxLines) {
                out.reason.append(Line(text: text, x: padX, baseline: baseline(top: y, height: reasonLineHeight, font: reasonFont)))
                y += reasonLineHeight
            }
        }
        if let preview = p.preview {
            y += sectionGap
            let inner = max(1, room - 2 * previewInset)
            let lines = wrap(preview, font: previewFont, width: inner, maxLines: previewMaxLines)
            let block = CGRect(x: padX, y: y, width: room, height: CGFloat(lines.count) * previewLineHeight + 2 * previewInset)
            var top = y + previewInset
            for text in lines {
                out.previewLines.append(Line(text: text, x: padX + previewInset,
                                             baseline: baseline(top: top, height: previewLineHeight, font: previewFont)))
                top += previewLineHeight
            }
            out.preview = block
            y = block.maxY
        }
        y += sectionGap
        var allowW = max(buttonMinWidth, (TextDraw.width(p.allowLabel, font: buttonFont) + 2 * buttonInset).rounded(.up))
        var denyW = max(buttonMinWidth, (TextDraw.width(p.denyLabel, font: buttonFont) + 2 * buttonInset).rounded(.up))
        if allowW + buttonGap + denyW > room {
            allowW = ((room - buttonGap) / 2).rounded(.down)
            denyW = allowW
        }
        let allow = CGRect(x: padX + room - allowW, y: y, width: allowW, height: buttonHeight)
        out.allow = allow
        out.deny = CGRect(x: allow.minX - buttonGap - denyW, y: y, width: denyW, height: buttonHeight)
        y += buttonHeight
        if let text = lineText(p) {
            y += statusGap
            for line in wrap(text, font: statusFont, width: room, maxLines: statusMaxLines) {
                out.lines.append(Line(text: line, x: padX, baseline: baseline(top: y, height: statusLineHeight, font: statusFont)))
                y += statusLineHeight
            }
        }
        out.size = CGSize(width: w.rounded(.up), height: (y + padY).rounded(.up))
        return out
    }

    /// One line, as tall as a one-line text bubble: the status, then " · " and the headline as
    /// far as it fits.
    private static func summaryLayout(_ p: Payload, width: CGFloat) -> Layout {
        let padX = Fixture.bubblePadX, padY = Fixture.bubblePadY
        let room = max(1, min(width, maxWidth) - 2 * padX)
        let status = fit(lineText(p) ?? "", font: summaryFont, width: room)
        let statusW = TextDraw.width(status, font: summaryFont)
        let base = baseline(top: padY, height: Fixture.lineHeight, font: summaryFont)
        var out = Layout(size: .zero)
        var used = statusW
        var rest: Line?
        let headline = codeSpans(p.prompt).text.replacingOccurrences(of: "\n", with: " ")
        let left = room - statusW
        if !headline.isEmpty, left > 40 {
            let text = fit(" \u{00B7} " + headline, font: statusFont, width: left)
            rest = Line(text: text, x: padX + statusW, baseline: base)
            used += TextDraw.width(text, font: statusFont)
        }
        out.summary = (Line(text: status, x: padX, baseline: base), rest)
        out.size = CGSize(width: (min(used, room) + 2 * padX).rounded(.up), height: (Fixture.lineHeight + 2 * padY).rounded(.up))
        return out
    }

    static func lineText(_ p: Payload) -> String? {
        switch p.status {
        case .pending: return p.error.map(CmuxStrings.approvalRefused) ?? p.note
        case .allowed: return p.device.map(CmuxStrings.approvalAllowedOn) ?? CmuxStrings.approvalAllowed
        case .denied: return p.device.map(CmuxStrings.approvalDeniedOn) ?? CmuxStrings.approvalDenied
        case .skipped: return CmuxStrings.approvalSkipped
        }
    }

    /// Which button `point` (the body's coordinates) is on: true Allow, false Deny, nil neither.
    static func button(at point: CGPoint, _ p: Payload, width: CGFloat) -> Bool? {
        let l = layout(p, width: width)
        if let r = l.allow, r.contains(point) { return true }
        if let r = l.deny, r.contains(point) { return false }
        return nil
    }

    // MARK: TranscriptCustomRowProvider

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .bubbleIncoming }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}

    func plainText(_ part: CustomPart) -> String? {
        guard let p = Self.payload(part) else { return nil }
        let prompt = Self.codeSpans(p.prompt).text
        guard p.status == .pending else { return [Self.lineText(p), prompt].compactMap { $0 }.joined(separator: "\n") }
        return [p.header, prompt, p.reason, p.preview, Self.lineText(p)].compactMap { $0 }.joined(separator: "\n")
    }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let p = Self.payload(part) else { return CGSize(width: min(maxWidth, 120), height: 32) }
        return Self.layout(p, width: maxWidth).size
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let p = Self.payload(part) else { return }
        let l = Self.layout(p, width: rect.width)
        let ink = Fixture.incomingText
        func at(_ r: CGRect) -> CGRect { r.offsetBy(dx: rect.minX, dy: rect.minY) }
        func draw(_ line: Line, font: UIFont, color: UIColor) {
            TextDraw.line(line.text, font: font, color: color, x: rect.minX + line.x, baseline: rect.minY + line.baseline, in: ctx)
        }
        if let summary = l.summary {
            draw(summary.status, font: Self.summaryFont, color: ink)
            if let rest = summary.rest { draw(rest, font: Self.statusFont, color: Fixture.secondaryText) }
            return
        }
        if let chip = l.chip, let header = p.header {
            Self.fill(ctx, at(chip), radius: Self.chipRadius, color: ink.withAlphaComponent(0.10))
            let text = Self.fit(header, font: Self.chipFont, width: chip.width - 2 * Self.chipInset)
            TextDraw.line(text, font: Self.chipFont, color: ink.withAlphaComponent(0.75), x: rect.minX + chip.minX + Self.chipInset,
                          baseline: rect.minY + Self.baseline(top: chip.minY, height: chip.height, font: Self.chipFont), in: ctx)
        }
        if let prompt = l.prompt {
            // drawText puts the first line's box at the bubble's top padding: shift the body to the headline's top.
            PartRenderer.drawText(ctx, prompt, in: rect.offsetBy(dx: 0, dy: l.promptTop - Fixture.bubblePadY), outgoing: false)
        }
        for line in l.reason { draw(line, font: Self.reasonFont, color: Fixture.secondaryText) }
        if let block = l.preview {
            Self.fill(ctx, at(block), radius: Self.previewRadius, color: ink.withAlphaComponent(0.07))
            for line in l.previewLines { draw(line, font: Self.previewFont, color: ink.withAlphaComponent(0.9)) }
        }
        if let r = l.deny { Self.button(ctx, at(r), title: p.denyLabel, primary: false, state: Self.buttonState(p, allow: false)) }
        if let r = l.allow { Self.button(ctx, at(r), title: p.allowLabel, primary: true, state: Self.buttonState(p, allow: true)) }
        let color = p.error != nil ? UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1) : Fixture.secondaryText
        for line in l.lines { draw(line, font: Self.statusFont, color: color) }
    }

    /// How a button draws.
    enum ButtonState: Equatable { case rest, hover, pressed, disabled }

    static func buttonState(_ p: Payload, allow: Bool) -> ButtonState {
        guard p.takesClicks else { return .disabled }
        guard let pointer = p.pointer, pointer.allow == allow else { return .rest }
        return pointer.pressed ? .pressed : .hover
    }

    /// A button in the question card's grays (AgentQuestionPillButton, `.acpmux-question-submit`):
    /// the primary fills with the text color and takes the bubble's color for its label (no
    /// accent); the secondary is a quiet fill. Hover and press deepen the fill; disabled dims both.
    private static func button(_ ctx: CGContext, _ r: CGRect, title: String, primary: Bool, state: ButtonState) {
        let ink = Fixture.incomingText
        let background = ink.withAlphaComponent(fillAlpha(primary: primary, state))
        let text = primary ? Fixture.incoming.withAlphaComponent(state == .disabled ? 0.6 : 1)
            : ink.withAlphaComponent(state == .disabled ? 0.45 : 1)
        fill(ctx, r, radius: buttonRadius, color: background)
        let label = fit(title, font: buttonFont, width: r.width - buttonInset)
        let width = TextDraw.width(label, font: buttonFont)
        TextDraw.line(label, font: buttonFont, color: text, x: (r.midX - width / 2).rounded(),
                      baseline: baseline(top: r.minY, height: r.height, font: buttonFont), in: ctx)
    }

    /// The button's fill: the text color at this opacity.
    static func fillAlpha(primary: Bool, _ state: ButtonState) -> CGFloat {
        switch state {
        case .rest: primary ? 1 : 0.10
        case .hover: primary ? 0.86 : 0.16
        case .pressed: primary ? 0.72 : 0.24
        case .disabled: primary ? 0.35 : 0.05
        }
    }

    private static func fill(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, color: UIColor) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: Clicks

    /// The button of the card `part` under `point` (the body's coordinates) that takes a click:
    /// true Allow, false Deny; nil off the buttons, or while the card takes no click.
    static func clickable(_ part: CustomPart, at point: CGPoint, size: CGSize) -> Bool? {
        guard part.kind == kind, let p = payload(part), p.takesClicks else { return nil }
        return button(at: point, p, width: size.width)
    }

    /// A thread view's click (`MessagesWindowView.hostControl`). The transcript's clicks come
    /// through ``ChatController/clicked(_:)``, which calls ``click(_:ref:allow:)`` itself.
    func tapped(_ part: CustomPart, ref: PartRef, at point: CGPoint, size: CGSize) -> Bool {
        // A click on the card but off its buttons is the card's (no menu, no selection change).
        guard let allow = Self.clickable(part, at: point, size: size) else { return true }
        guard let why = click(part, ref: ref, allow: allow) else { return true }
        // The pane that shows the card has its message; another pane's store has none (no change).
        guard Thread.isMainThread else { return true }
        // main-proof: guarded by Thread.isMainThread above
        MainActor.assumeIsolated {
            for owner in owners.allObjects { owner.controller.showApprovalRefusal(why, ref: ref) }
        }
        return true
    }

    /// A click on Allow (`allow`) or Deny of the card `part` at `ref`, on the main thread: the
    /// projection that shows the message starts the decision. nil when a decision started or is
    /// already in flight (the card draws it); else why nothing could start, which this Mac's state
    /// keeps for the card and the caller shows on it now.
    func click(_ part: CustomPart, ref: PartRef, allow: Bool) -> String? {
        // Clicks arrive on main; anything else is refused, never trapped.
        guard Thread.isMainThread else { return CmuxStrings.approvalUnavailable }
        // main-proof: guarded by Thread.isMainThread above
        let outcome: HomeApprovalClick = MainActor.assumeIsolated {
            for owner in owners.allObjects {
                let result = owner.decideApproval(ref, allow: allow)
                if result != .notShown { return result }
            }
            return .notShown
        }
        let why: String
        switch outcome {
        case .started, .inFlight: return nil
        case .refused(let reason): why = reason
        // No projection here shows the message (it left the window, or its pane closed).
        case .notShown: why = CmuxStrings.approvalUnavailable
        }
        if let p = Self.payload(part) { setLocal(Self.key(p), Local(error: why)) }
        return why
    }
}

/// What a click on an approval card's button did (``HomeProjection/decideApproval(_:allow:)``).
enum HomeApprovalClick: Equatable, Sendable {
    /// This projection does not show the message (another pane's card).
    case notShown
    /// The decision started (the card's buttons are off until it ends).
    case started
    /// A decision of this card is already in flight: the click changes nothing.
    case inFlight
    /// No decision could start: why (the card shows it).
    case refused(String)
}
