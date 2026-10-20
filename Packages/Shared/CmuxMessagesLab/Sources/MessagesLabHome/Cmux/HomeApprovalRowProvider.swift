import CmuxAgentQuestion
import CoreGraphics
import Foundation
import os

/// cmux: the Chief's permission approval in Home, as a drawn custom row (CustomRows.swift,
/// `Part.custom` of kind ``kind``) with Allow and Deny buttons.
///
/// The Chief posts the approval as a `question` part of harness `chief` with a `permission`
/// (optchat-chief `brain/approvals.rs`): one item `approval`, options `allow` and `deny`.
/// `HomeMapping.part` maps that part here while the provider is registered; any other question
/// stays text. The card draws the prompt, then the two buttons while the question is pending, or
/// one line once it is answered or cancelled. A click on a button goes to the projection that
/// shows the message (``HomeProjection/decideApproval(_:allow:)``): it answers acpmux as the
/// person, then the part (`question.answer`).
///
/// While a decision is in flight its buttons draw disabled and take no click; a refused decision
/// shows its error under the buttons, which take clicks again (plans/cmux-next/agent-questions.md
/// §6, §7). That state is this Mac's, not the conversation's: it lives in ``local`` by
/// session and permission, and the mapping copies it into the payload, so a rebuild keeps it.
final class HomeApprovalRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.approval"
    /// The item and options the Chief's approval question carries (optchat-chief's contract).
    static let item = "approval"
    static let allowOption = "allow"
    static let denyOption = "deny"
    /// The widest card (a long command wraps inside it).
    static let maxWidth: CGFloat = 380
    static let buttonHeight: CGFloat = 28
    static let buttonGap: CGFloat = 8
    /// Space between the prompt and the buttons or the status line.
    static let sectionGap: CGFloat = 10
    /// A prompt longer than this is cut (the whole request stays in the agent tab).
    static let maxPrompt = 1_200
    static let buttonFont = HomeFonts.system(ofSize: 13, weight: .semibold)
    static let statusFont = HomeFonts.system(ofSize: 12)

    /// The one provider (registered once per process, as the diagram provider).
    static let shared = HomeApprovalRowProvider()

    /// Where the card stands, as the payload carries it.
    enum Status: String, Codable {
        case pending, allowed, denied, skipped
    }

    struct Payload: Codable, Equatable {
        var session: String
        var permission: String
        var prompt: String
        var status: Status
        /// The device that answered (a paired iPhone), nil for this Mac or unknown.
        var device: String?
        /// This Mac's decision is in flight (the buttons draw disabled).
        var busy = false
        /// This Mac's last decision was refused: why.
        var error: String?
    }

    /// This Mac's state of one approval (`local`).
    struct Local: Equatable {
        var busy = false
        var error: String?
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
              item.options.contains(where: { $0.id == Self.allowOption }), item.options.contains(where: { $0.id == Self.denyOption })
        else { return nil }
        var payload = Payload(session: question.source.session, permission: permission,
                              prompt: String(item.prompt.prefix(Self.maxPrompt)), status: .pending)
        switch question.state {
        case .pending:
            let mine = local(Self.key(session: payload.session, permission: permission))
            payload.busy = mine.busy
            payload.error = mine.error
        case .cancelled:
            payload.status = .skipped
        case .answered(let answer):
            let chosen = answer.selections[Self.item]?.optionIDs ?? []
            payload.status = chosen.contains(Self.allowOption) ? .allowed : .denied
            payload.device = answer.respondent?.device
        }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return .custom(CustomPart(kind: Self.kind, version: Self.version(data), payload: data))
    }

    static func payload(_ part: CustomPart) -> Payload? { part.decode(Payload.self) }

    /// A stable version per payload (FNV-1a): the measure cache and the row bitmaps key on it.
    static func version(_ data: Data) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in data { hash = (hash ^ UInt32(truncatingIfNeeded: byte)) &* 16_777_619 }
        return Int(truncatingIfNeeded: hash & 0x7fff_ffff)
    }

    // MARK: Layout (one function for measure, draw and the click)

    struct Layout {
        var size: CGSize
        var prompt: TextLayout
        /// The buttons (pending only), in the body's coordinates (y down).
        var allow: CGRect?
        var deny: CGRect?
        /// The status line (answered, cancelled) or the error line (pending, refused).
        var line: (text: String, baseline: CGFloat)?
    }

    static func layout(_ p: Payload, width: CGFloat) -> Layout {
        let w = min(width, maxWidth)
        let padX = Fixture.bubblePadX, padY = Fixture.bubblePadY
        let room = max(1, w - 2 * padX)
        let prompt = TextLayout.make(p.prompt, runs: [], maxWidth: room)
        var y = padY + prompt.textHeight(hard: Fixture.lineHeight)
        var out = Layout(size: .zero, prompt: prompt)
        if p.status == .pending {
            y += sectionGap
            let half = (room - buttonGap) / 2
            out.allow = CGRect(x: padX, y: y, width: half, height: buttonHeight)
            out.deny = CGRect(x: padX + half + buttonGap, y: y, width: half, height: buttonHeight)
            y += buttonHeight
        }
        if let text = lineText(p) {
            y += sectionGap - 4
            out.line = (text, y + Fixture.lineHeight - 4)
            y += Fixture.lineHeight
        }
        out.size = CGSize(width: w.rounded(.up), height: (y + padY).rounded(.up))
        return out
    }

    static func lineText(_ p: Payload) -> String? {
        switch p.status {
        case .pending: return p.error.map(CmuxStrings.approvalRefused)
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
        return ([p.prompt] + [Self.lineText(p)].compactMap { $0 }).joined(separator: "\n")
    }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        guard let p = Self.payload(part) else { return CGSize(width: min(maxWidth, 120), height: 32) }
        return Self.layout(p, width: maxWidth).size
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let p = Self.payload(part) else { return }
        let l = Self.layout(p, width: rect.width)
        PartRenderer.drawText(ctx, l.prompt, in: rect, outgoing: false)
        let alpha: CGFloat = p.busy ? 0.45 : 1
        if let r = l.allow {
            Self.button(ctx, r.offsetBy(dx: rect.minX, dy: rect.minY), title: CmuxStrings.approvalAllow,
                        fill: Fixture.incomingLink.withAlphaComponent(alpha), text: UIColor.white.withAlphaComponent(alpha))
        }
        if let r = l.deny {
            Self.button(ctx, r.offsetBy(dx: rect.minX, dy: rect.minY), title: CmuxStrings.approvalDeny,
                        fill: Fixture.incomingText.withAlphaComponent(0.14 * alpha), text: Fixture.incomingText.withAlphaComponent(alpha))
        }
        if let line = l.line {
            let color = p.status == .pending ? UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1) : Fixture.secondaryText
            TextDraw.line(line.text, font: Self.statusFont, color: color, x: rect.minX + Fixture.bubblePadX,
                          baseline: rect.minY + line.baseline, in: ctx)
        }
    }

    private static func button(_ ctx: CGContext, _ r: CGRect, title: String, fill: UIColor, text: UIColor) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        let width = TextDraw.width(title, font: buttonFont)
        TextDraw.line(title, font: buttonFont, color: text, x: r.midX - width / 2, baseline: r.midY + 4.5, in: ctx)
    }

    func tapped(_ part: CustomPart, ref: PartRef, at point: CGPoint, size: CGSize) -> Bool {
        guard let p = Self.payload(part) else { return false }
        // A click on the card but off its buttons is the card's (no menu, no selection change).
        guard p.status == .pending, !p.busy, let allow = Self.button(at: point, p, width: size.width) else { return true }
        // The click comes on the main thread (MessagesWindowView.hostControl); the projection that
        // shows the message takes it (another pane's answers false). A second click before this
        // runs finds the decision in flight (HomeProjection.decideApproval).
        let owners = owners.allObjects
        Task { @MainActor in _ = owners.first { $0.decideApproval(ref, allow: allow) } }
        return true
    }
}
