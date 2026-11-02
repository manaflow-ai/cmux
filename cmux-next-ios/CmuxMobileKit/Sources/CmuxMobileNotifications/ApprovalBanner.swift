import Foundation

/// A permission request as the Mac's approval prompt for a streaming device
/// shows one (`MacScreenApprovalView`: "<device> wants to control this Mac",
/// "Asks for …", the device key fingerprint, Deny and Allow Once, then the
/// lasting grants): who asks and where, what for, the request itself in
/// code type, and the answers in the Mac's order. The banner text
/// (`PushBanner`, the Worker's `alert`) and the long-press card (the content
/// extension) both come from here, so the phone's approval reads like the
/// Mac's while the app is not in the foreground.
public struct ApprovalBanner: Equatable, Sendable {
    /// The accent glyph before the title (SF Symbols).
    public static let glyph = "hand.raised"

    /// "<Agent> wants to act on <Mac>".
    public var title: String
    /// The secondary line under the title: "Asks to run this in <workspace>."
    public var scope: String
    /// The caption over `detail` ("Request"), as the Mac's "Device key fingerprint".
    public var detailLabel: String
    /// The tool's own title (a command, a file), in code type; nil when the Mac sent none.
    public var detail: String?
    /// The leading, destructive answer (Deny).
    public var deny: PushForm.Row?
    /// The trailing, prominent answer: the single-use Allow, else the lasting one offered.
    public var allow: PushForm.Row?
    /// The other answers, compact under the two (a lasting grant next to a single-use one).
    public var more: [PushForm.Row]

    /// The prompt for `payload`; nil for anything but a permission request.
    public init?(payload p: PushPayload) {
        guard p.kind == .permission else { return nil }
        let agent = p.agent ?? String(localized: "Your agent")
        title = Self.title(agent: agent, mac: p.macDisplayName)
        scope = p.placeName.flatMap { $0.isEmpty ? nil : $0 }.map { String(localized: "Asks to run this in \($0).") }
            ?? String(localized: "Asks to run this.")
        detailLabel = String(localized: "Request")
        detail = Self.detail(p)
        // One row per option id, in the Mac's order.
        var seen = Set<String>()
        let rows = PushForm(payload: p).rows.filter { seen.insert($0.id).inserted }
        let kinds = Dictionary(p.options.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        // The single-use answers lead, as the notification's own buttons (`PushActions.plan`).
        let deny = rows.first { $0.style == .deny && kinds[$0.id] == .rejectOnce } ?? rows.first { $0.style == .deny }
        let allow = rows.first { $0.style == .allow && kinds[$0.id] == .allowOnce } ?? rows.first { $0.style == .allow }
        self.deny = deny
        self.allow = allow
        more = rows.filter { $0.id != deny?.id && $0.id != allow?.id }
    }

    /// The request: the tool's title, else the body; an empty one counts as none (the Worker's `||`).
    static func detail(_ p: PushPayload) -> String? {
        [p.title, p.body].lazy.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The banner title, shared with `PushBanner` and the Worker's `alert`.
    static func title(agent: String, mac: String) -> String {
        String(localized: "\(agent) wants to act on \(mac)")
    }
}
