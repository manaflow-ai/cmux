import AppKit
import CmuxHomeCore
import CoreGraphics
import CoreText
import Foundation

/// cmux: an agent-message fold or notes row as a small muted caption line, not a bubble (user
/// 2026-10-31, msg 19414: the "▸ Agent messages (3) · a957" header, a blue underlined link in a gray
/// pill, "is bad"), and each status note of an opened notes row. A drawn custom row (CustomRows.swift, `.fullWidth`) like the table cards
/// (``HomeTableRowProvider``): a chevron, the label ("Agent messages (3)", "Disconnected (5)") and
/// the agents as plain chips, at the bubbles' left edge. A click anywhere on the line opens or closes
/// the fold (`ChatIntents.agentRowClicked`); the provider takes no click itself.
final class HomeAgentFoldRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.agentFold"
    /// The line's height.
    static let height: CGFloat = 22
    /// Chevron box, gaps and chip metrics.
    static let chevronWidth: CGFloat = 10
    static let gap: CGFloat = 6
    static let chipHeight: CGFloat = 16
    static let chipPadX: CGFloat = 6
    static let chipGap: CGFloat = 4

    struct Payload: Codable, Hashable {
        var open: Bool
        var label: String
        var chips: [String]
        /// False for an opened note's line: no chevron, the text indented under the fold's label.
        var chevron = true
    }

    /// The registered provider (nil: fold rows stay text bubbles).
    static var installed: HomeAgentFoldRowProvider? { CustomRows.provider(kind) as? HomeAgentFoldRowProvider }

    /// Registers the provider once per process.
    static func install() {
        if installed == nil { CustomRows.register(HomeAgentFoldRowProvider()) }
    }

    /// The caption part for a fold or notes row; nil for a message or note row, or when not installed.
    static func part(_ row: HomeAgentMessageRow) -> Part? {
        guard installed != nil else { return nil }
        let payload: Payload
        switch row.kind {
        case let .fold(count, peers, expanded):
            payload = Payload(open: expanded, label: expanded ? CmuxStrings.hideAgentMessages(count) : CmuxStrings.showAgentMessages(count),
                              chips: expanded ? [] : peers)
        case let .notes(count, peers, reason, expanded):
            payload = Payload(open: expanded, label: CmuxStrings.agentNotes(reason, count), chips: expanded ? [] : peers)
        case let .note(peer, _, text):
            payload = Payload(open: false, label: "\(peer) · \(text)", chips: [], chevron: false)
        case .message:
            return nil
        }
        let key = "\(payload.chevron)\u{0}\(payload.open)\u{0}\(payload.label)\u{0}\(payload.chips.joined(separator: ","))"
        guard let custom = try? CustomPart(kind: kind, version: HomeDiagramRowProvider.version(key), value: payload) else { return nil }
        return .custom(custom)
    }

    /// The caption part for a Feed row (``HomeFeedRow``): its source and title on one muted line with
    /// no chevron, like a status note; nil when not installed (the row's text shows instead).
    static func part(feed row: HomeFeedRow) -> Part? {
        guard installed != nil else { return nil }
        let payload = Payload(open: false, label: row.source.isEmpty ? row.title : "\(row.source) · \(row.title)", chips: [], chevron: false)
        let key = "feed\u{0}\(payload.label)"
        guard let custom = try? CustomPart(kind: kind, version: HomeDiagramRowProvider.version(key), value: payload) else { return nil }
        return .custom(custom)
    }

    static func payload(_ part: CustomPart) -> Payload? { part.decode(Payload.self) }

    // MARK: TranscriptCustomRowProvider

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .fullWidth }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { CGSize(width: maxWidth, height: Self.height) }
    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { CGSize(width: maxWidth, height: Self.height) }

    func plainText(_ part: CustomPart) -> String? {
        guard let payload = Self.payload(part) else { return nil }
        return payload.chips.isEmpty ? payload.label : "\(payload.label) · \(payload.chips.joined(separator: ", "))"
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let payload = Self.payload(part) else { return }
        HomeAgentFoldLine(payload, width: rect.width).draw(ctx, at: rect.origin)
    }
}
