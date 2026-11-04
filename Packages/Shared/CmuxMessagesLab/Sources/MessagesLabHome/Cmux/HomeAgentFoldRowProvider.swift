import AppKit
import CmuxHomeCore
import CoreGraphics
import CoreText
import Foundation

/// cmux: an agents row as one pill per agent (``HomeAgentPills``, user 2026-11-03, msg 19960), and a status
/// note or Feed row as a small muted caption line. Before the pills, every row was that line (user
/// 2026-10-31, msg 19414: the "▸ Agent messages (3) · a957" header, a blue underlined link in a gray
/// pill, "is bad"), and each status note of an opened agents row. A drawn custom row (CustomRows.swift, `.fullWidth`) like the table cards
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
        /// The header style that draws it (`HomeAgentFoldStyle` raw value in DEBUG); 0, the shipped look, elsewhere.
        var style = 0
        /// What the row is: `fold` (an agents row), `note` or `feed` (a Feed row always draws the shipped look).
        var role = "fold"
        /// An agents row's message count.
        var count = 0
        /// An agents row's agents (all of them; `chips` is what the shipped look names).
        var peers: [String] = []
        /// Each agent's state, in `peers` order: `told`, `reported` or `stopped`.
        var states: [String] = []
        /// The newest message's words (a one-line preview).
        var latest: String?
        /// Each agent's title, in `peers` order (``HomeAgentMessageRow/peerTitles``).
        var titles: [String] = []
        /// Each agent's unread dot, in `peers` order (``HomeAgentMessageRow/peerUnread``); empty: a report is unread.
        var unread: [Bool] = []
    }

    /// The header style this provider draws (DEBUG: the Agent Messages Playground registers another).
    let style: Int

    /// A click on an agent's pill (DEBUG pill styles): the agent's id and the row, on the main actor.
    let onPill: (@MainActor @Sendable (String, PartRef) -> Void)?

    /// - Parameters:
    ///   - style: The header style (`HomeAgentFoldStyle` raw value in DEBUG); 0, the shipped look.
    ///   - onPill: What a click on an agent's pill does (the Agent Messages Playground); nil: the click folds as before.
    init(style: Int = 0, onPill: (@MainActor @Sendable (String, PartRef) -> Void)? = nil) {
        self.style = style
        self.onPill = onPill
    }

    /// The registered provider (nil: fold rows stay text bubbles).
    static var installed: HomeAgentFoldRowProvider? { CustomRows.provider(kind) as? HomeAgentFoldRowProvider }

    /// Registers the provider once per process.
    static func install() {
        if installed == nil { CustomRows.register(HomeAgentFoldRowProvider()) }
    }

    /// The part for an agents row or a status note; nil for a message row, or when not installed.
    static func part(_ row: HomeAgentMessageRow) -> Part? { installed?.part(row) }

    /// The part for an agents row or a status note, drawn in this provider's style; nil for a message row.
    func part(_ row: HomeAgentMessageRow) -> Part? {
        var payload: Payload
        switch row.kind {
        case let .fold(count, peers, expanded):
            payload = Payload(open: expanded, label: expanded ? CmuxStrings.hideAgentMessages(count) : CmuxStrings.showAgentMessages(count),
                              chips: expanded ? [] : peers)
            (payload.role, payload.count, payload.peers) = ("fold", count, peers)
        case let .note(peer, _, text):
            payload = Payload(open: false, label: "\(peer) · \(text)", chips: [], chevron: false)
            (payload.role, payload.count, payload.peers, payload.states) = ("note", 1, [peer], ["stopped"])
        case .message:
            return nil
        }
        if payload.role != "note" { payload.states = row.peerStates.map { "\($0)" } }
        payload.latest = row.latest
        payload.titles = row.peerTitles
        payload.unread = row.peerUnread
        payload.style = style
        let key = [String(describing: payload.style), payload.role, "\(payload.chevron)", "\(payload.open)", payload.label,
                   payload.chips.joined(separator: ","), payload.peers.joined(separator: ","), payload.states.joined(separator: ","),
                   payload.latest ?? "", payload.titles.joined(separator: "\u{1}"),
                   payload.unread.map { $0 ? "1" : "0" }.joined()].joined(separator: "\u{0}")
        guard let custom = try? CustomPart(kind: Self.kind, version: HomeDiagramRowProvider.version(key), value: payload) else { return nil }
        return .custom(custom)
    }

    /// The caption part for a Feed row (``HomeFeedRow``): its source and title on one muted line with
    /// no chevron, like a status note; nil when not installed (the row's text shows instead).
    static func part(feed row: HomeFeedRow) -> Part? {
        guard installed != nil else { return nil }
        var payload = Payload(open: false, label: row.source.isEmpty ? row.title : "\(row.source) · \(row.title)", chips: [], chevron: false)
        payload.role = "feed"
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
    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { CGSize(width: maxWidth, height: Self.height(Self.payload(part))) }
    func estimate(_ part: CustomPart, maxWidth: CGFloat) -> CGSize { measure(part, maxWidth: maxWidth) }

    /// The row's height: an agents row's pills, a note's or Feed row's caption line, or in DEBUG its playground style's.
    private static func height(_ payload: Payload?) -> CGFloat {
        guard let payload else { return height }
        #if DEBUG
        if let style = HomeAgentFoldStyle.drawing(payload) { return style.height(payload) }
        #endif
        return drawsPills(payload) ? HomeAgentPills(payload, shape: .pill, width: .greatestFiniteMagnitude).height : height
    }

    /// The agent whose pill of the shipped agents row `part` holds `point` (the row's body coordinates,
    /// a body `width` wide), or nil: not an agents row, or between pills. The host opens that agent's chat.
    static func peer(_ part: CustomPart, at point: CGPoint, width: CGFloat) -> String? {
        guard part.kind == kind, let payload = payload(part), drawsPills(payload) else { return nil }
        #if DEBUG
        if let style = HomeAgentFoldStyle.drawing(payload) {
            return style.pillShape.flatMap { HomeAgentPills(payload, shape: $0, width: width).peer(at: point) }
        }
        #endif
        return HomeAgentPills(payload, shape: .pill, width: width).peer(at: point)
    }

    /// True for an agents row: the shipped look draws it as one pill per agent.
    static func drawsPills(_ payload: Payload) -> Bool { payload.role == "fold" }

    func plainText(_ part: CustomPart) -> String? {
        guard let payload = Self.payload(part) else { return nil }
        return payload.chips.isEmpty ? payload.label : "\(payload.label) · \(payload.chips.joined(separator: ", "))"
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let payload = Self.payload(part) else { return }
        #if DEBUG
        if let style = HomeAgentFoldStyle.drawing(payload) {
            style.draw(payload, in: ctx, rect: rect)
            return
        }
        #endif
        if Self.drawsPills(payload) {
            HomeAgentPills(payload, shape: .pill, width: rect.width).draw(ctx, origin: rect.origin)
        } else {
            HomeAgentFoldLine(payload, width: rect.width).draw(ctx, at: rect.origin)
        }
    }

    /// DEBUG pill styles: a click on a pill goes to ``onPill`` with that agent; elsewhere the row folds as before.
    func tapped(_ part: CustomPart, ref: PartRef, at point: CGPoint, width: CGFloat) -> Bool {
        #if DEBUG
        guard let onPill, let payload = Self.payload(part), payload.role != "note",
              let shape = HomeAgentFoldStyle.drawing(payload)?.pillShape,
              let peer = HomeAgentPills(payload, shape: shape, width: width).peer(at: point) else { return false }
        Task { @MainActor in onPill(peer, ref) }
        return true
        #else
        return false
        #endif
    }
}
