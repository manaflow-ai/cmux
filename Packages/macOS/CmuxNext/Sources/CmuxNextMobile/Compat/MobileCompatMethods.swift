/// The shipped-iOS mobile RPC inventory and what the cmux-next adapter does
/// with each method. Unlisted methods answer `method_not_found`; the phone
/// gates every such feature on a capability this Mac does not advertise.
public enum MobileCompatMethods {
    public enum Support: String, Sendable {
        /// Backed by the daemon tree or a terminal attach.
        case implemented
        /// Accepted and answered without effect (focus is phone-local now).
        case acknowledged
        /// Answers `method_not_found` on purpose (the phone falls back).
        case fallback
    }

    public static let table: [String: Support] = [
        "mobile.host.status": .implemented,
        "mobile.rpc.methods": .implemented,
        "mobile.events.subscribe": .implemented,
        "mobile.events.unsubscribe": .implemented,
        "mobile.events.probe": .implemented,
        "mobile.sync.fetch": .fallback,
        "mobile.workspace.list": .implemented,
        "workspace.list": .implemented,
        "workspace.create": .implemented,
        "workspace.close": .implemented,
        "workspace.action": .implemented,
        "mobile.terminal.create": .implemented,
        "terminal.create": .implemented,
        "mobile.terminal.replay": .implemented,
        "terminal.replay": .implemented,
        "mobile.terminal.viewport": .implemented,
        "terminal.viewport": .implemented,
        "mobile.terminal.input": .implemented,
        "terminal.input": .implemented,
        "mobile.terminal.paste": .implemented,
        "terminal.paste": .implemented,
        "mobile.terminal.close": .implemented,
        "mobile.terminal.rename": .implemented,
        "mobile.surface.focus": .acknowledged,
    ]

    /// Methods listed by `mobile.rpc.methods` (sorted, excluding fallbacks).
    public static var served: [String] {
        table.filter { $0.value != .fallback }.keys.sorted()
    }
}
