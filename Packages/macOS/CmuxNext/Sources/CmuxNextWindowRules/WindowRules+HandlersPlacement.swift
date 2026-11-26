public import CmuxNextDaemon
public import Foundation

/// The placement handlers' rules (cmux-window-rules `handlers_placement`, ops `handlers_placement_*`): how
/// New ▸ Kind ▸ Placement reaches its place, a split edge's direction, and the dock actions' edges, modes
/// and refusals. The app reads the facts and runs the answer. Each method answers nil when the FFI does not.
extension WindowRules {
    /// How a New ▸ Kind ▸ Placement run goes (`handlers_placement_new_at`).
    public nonisolated struct NewAtRoute: Equatable, Sendable {
        /// The kind's own create makes it there; else it is made here and moved.
        public var ownCreate: Bool
        /// A browser made here is marked agent-driven before its first load.
        public var agentDriven: Bool
        /// Refused: the pane's daemon makes no browser tab a move can take (`frontend-browser-tabs-v1`).
        public var needsFrontendBrowserTabs: Bool
    }

    /// The route for `kind` at layout op `op` (`split` with `edge`, `column` with `left`, `row`, `tab`,
    /// `workspace`, `window`), run from `origin` (an `ActionOrigin` raw value). An FFI that does not answer:
    /// made here and moved, which reaches every place.
    public func newAt(kind: String, op: String, edge: String? = nil, left: Bool? = nil, madeInPlace: Bool, origin: String,
                      frontendBrowserTabs: Bool) -> NewAtRoute {
        struct Facts: Encodable {
            var kind, op: String, edge: String?, left: Bool?, madeInPlace: Bool, origin: String, frontendBrowserTabs: Bool
        }
        struct Reply: Decodable {
            struct Create: Decodable { var create: String }
            var route: String, create: Create?, agentDriven: Bool?
        }
        let facts = Facts(kind: kind, op: op, edge: edge, left: left, madeInPlace: madeInPlace, origin: origin,
                          frontendBrowserTabs: frontendBrowserTabs)
        guard let reply = call("handlers_placement_new_at", facts, as: Reply.self) else {
            return NewAtRoute(ownCreate: false, agentDriven: false, needsFrontendBrowserTabs: false)
        }
        return NewAtRoute(ownCreate: reply.create != nil, agentDriven: reply.agentDriven ?? false,
                          needsFrontendBrowserTabs: reply.route == "needsFrontendBrowserTabs")
    }

    /// The gate a New ▸ Kind ▸ Placement action waits on: `row`, `columnLeft` or none.
    public func newAtGate(kind: String, place: String) -> String? {
        struct Ask: Encodable { var kind, place: String }
        struct Reply: Decodable { var gate: String? }
        return call("handlers_placement_new_at_gate", Ask(kind: kind, place: place), as: Reply.self)?.gate
    }

    /// The pane direction a split edge opens toward.
    public func splitDirection(_ edge: String) -> PaneDirection? {
        struct Ask: Encodable { var place: String }
        struct Reply: Decodable { var direction: String }
        return call("handlers_placement_direction", Ask(place: edge), as: Reply.self).flatMap { PaneDirection(rawValue: $0.direction) }
    }

    /// The dock settings' defaults from cmux.json `layout.dockColumnEdge` and `layout.dockColumnMode` raw values.
    public nonisolated struct DockSettings: Decodable, Equatable, Sendable {
        /// The configured edge; nil for `nearest`, which leaves the choice to `DockDefaults`.
        public var configuredEdge: String?
        /// The configured edge, else right.
        public var defaultEdge: String
        /// Overlay when set so, else docked.
        public var defaultMode: String
    }

    private nonisolated struct DockRequest: Encodable {
        var action = "", edge: String?, mode: String?, settingEdge: String, settingMode: String
    }

    public func dockSettings(edge: String, mode: String) -> DockSettings? {
        call("handlers_placement_dock_settings", DockRequest(edge: nil, mode: nil, settingEdge: edge, settingMode: mode), as: DockSettings.self)
    }

    /// The edge and mode dock action `action` asks for from its `edge` and `mode` arguments and the settings'
    /// raw values; a nil part is the column's nearer edge or the daemon's mode. Nil for no dock action.
    public func dockAsk(_ action: String, edge: String?, mode: String?, settingEdge: String,
                        settingMode: String) -> (edge: String?, mode: String?)? {
        struct Reply: Decodable { var edge: String?, mode: String? }
        let request = DockRequest(action: action, edge: edge, mode: mode, settingEdge: settingEdge, settingMode: settingMode)
        return call("handlers_placement_dock_ask", request, as: Reply.self).map { ($0.edge, $0.mode) }
    }

    /// How a refused dock change fails: `noTarget` or else invalid target, and the reason the app words
    /// (`noColumnShown`, `lastScrollingColumn`, `columnNotDocked`, `columnAlreadyDocked`).
    public func dockFailure(refusal: String, undocking: Bool) -> (noTarget: Bool, reason: String)? {
        struct Ask: Encodable { var refusal: String, undocking: Bool }
        struct Reply: Decodable { var failure, reason: String }
        return call("handlers_placement_dock_failure", Ask(refusal: refusal, undocking: undocking), as: Reply.self)
            .map { ($0.failure == "noTarget", $0.reason) }
    }
}
