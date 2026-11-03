import AppKit
import CmuxAgentQuestion
import CmuxHomeRender

/// A narrow Chief subagent approval row using the transcript's text and bubble renderer.
/// No generic question handling, new motion, or persistent permission choices.
final class HomeApprovalRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.hiddenApproval"
    struct Local: Codable, Equatable {
        var busy = false
        var note: String?
        var ended = false
    }
    struct Payload: Codable, Equatable {
        var question: AgentQuestion
        var local: Local
        var pointer: Bool?
        var takesClicks: Bool { question.isPending && !local.busy && !local.ended }
    }
    @MainActor static func install() {
        if CustomRows.provider(kind) == nil { CustomRows.register(HomeApprovalRowProvider()) }
    }
    /// This marker identifies the narrow card shape; authorization compares the full request snapshot.
    static func digest(_ question: AgentQuestion) -> String? {
        guard question.source.harness == .chief, question.source.permission != nil,
              question.items.count == 1, let item = question.items.first,
              item.id.hasPrefix("approval:"), !item.multiSelect, !item.allowsOther,
              Set(item.options.map(\.id)) == ["allow", "deny"] else { return nil }
        let digest = String(item.id.dropFirst("approval:".count))
        return digest.count == 64 && digest.allSatisfy({ "0123456789abcdef".contains($0) }) ? digest : nil
    }
    static func part(_ question: AgentQuestion, local: Local = .init()) -> Part? {
        guard Self.digest(question) != nil,
              let custom = Self.custom(Payload(question: question, local: local)) else { return nil }
        return .custom(custom)
    }
    static func custom(_ payload: Payload) -> CustomPart? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return CustomPart(kind: kind, version: HomeDiagramRowProvider.version(String(decoding: data, as: UTF8.self)), payload: data)
    }
    static func payload(_ part: CustomPart) -> Payload? { part.kind == kind ? part.decode(Payload.self) : nil }
    static func text(_ p: Payload) -> String {
        let question = p.question
        let title = question.items.first?.prompt ?? ""
        let status: String? = switch question.state {
        case .pending: p.local.note
        case .cancelled: CmuxStrings.approvalExpired
        case .answered(let answer): answer.selections.values.contains { $0.optionIDs.contains("allow") }
            ? (isConnect(question) ? CmuxStrings.approvalConnected : CmuxStrings.approvalAllowed)
            : (isConnect(question) ? CmuxStrings.approvalNotConnected : CmuxStrings.approvalDenied)
        }
        let snapshot = question.items.first?.options.first { $0.id == "allow" }?.preview?.text
        let request = snapshot.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        let raw = (request?["toolCall"] as? [String: Any])?["rawInput"]
        let input = question.isPending ? raw.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]) }.map { String(decoding: $0, as: UTF8.self) } : nil
        return visible([title, input, status].compactMap { $0 }.joined(separator: "\n\n"))
    }
    /// An agent's MCP connect card (optchat-chief brain/home_mcp_connect.rs): its buttons say Connect and
    /// Don't connect; the app answers acpmux's card, not a tool permission (ChiefApprovalDecider).
    static func isConnect(_ question: AgentQuestion) -> Bool {
        question.source.permission?.hasPrefix("mcp-connect:") == true
    }
    /// Never let invisible direction/zero-width characters disguise the requested command.
    static func visible(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x061C, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF:
                String(format: "<U+%04X>", scalar.value)
            default: String(scalar)
            }
        }.joined()
    }
    struct Layout {
        let text: TextLayout
        let size: CGSize
        let allow: CGRect
        let deny: CGRect
    }
    static func layout(_ p: Payload, width: CGFloat) -> Layout {
        let width = max(80, min(420, width))
        let pad = Fixture.bubblePadX
        let text = TextLayout.make(Self.text(p), runs: [], maxWidth: max(1, width - 2 * pad))
        let top = text.textHeight(hard: Fixture.lineHeight) + 2 * Fixture.bubblePadY
        let buttons = p.question.isPending && !p.local.ended
        let buttonWidth = max(1, (width - 2 * pad - 8) / 2)
        return Layout(text: text, size: CGSize(width: width, height: top + (buttons ? 36 : 0)),
                      allow: CGRect(x: pad + buttonWidth + 8, y: top, width: buttonWidth, height: buttons ? 26 : 0),
                      deny: CGRect(x: pad, y: top, width: buttonWidth, height: buttons ? 26 : 0))
    }
    static func button(at point: CGPoint, _ p: Payload, width: CGFloat) -> Bool? {
        let layout = layout(p, width: width)
        if layout.allow.height > 0, layout.allow.contains(point) { return true }
        if layout.deny.height > 0, layout.deny.contains(point) { return false }
        return nil
    }
    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .bubbleIncoming }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func plainText(_ part: CustomPart) -> String? { Self.payload(part).map(Self.text) }
    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        Self.payload(part).map { Self.layout($0, width: maxWidth).size } ?? .zero
    }
    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let p = Self.payload(part) else { return }
        let layout = Self.layout(p, width: rect.width)
        PartRenderer.drawText(ctx, layout.text, in: rect, outgoing: false)
        let font = Fixture.bodyFont
        for (allow, button) in [(true, layout.allow), (false, layout.deny)] where button.height > 0 {
            let r = button.offsetBy(dx: rect.minX, dy: rect.minY)
            let ink = Fixture.incomingText
            ctx.setFillColor(ink.withAlphaComponent(p.takesClicks ? (allow ? 1 : 0.1) : 0.2).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
            let connect = Self.isConnect(p.question)
            let title = allow ? (connect ? CmuxStrings.approvalConnect : CmuxStrings.approvalAllow)
                : (connect ? CmuxStrings.approvalDontConnect : CmuxStrings.approvalDeny)
            let color = allow ? Fixture.incoming : ink
            TextDraw.line(title, font: font, color: color, x: r.midX - TextDraw.width(title, font: font) / 2,
                          baseline: r.midY + (font.ascender + font.descender) / 2, in: ctx)
        }
    }
}
