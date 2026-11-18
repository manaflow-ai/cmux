import Foundation
import Observation

// What an agent UI surface card sends, and only this (plans/cmux-next/agent-ui-surfaces-DESIGN.md):
// the renderer never builds a payload. A press sends the action's id and the field values the card
// holds, by bind; Rust answers with the host-written Pending the card shows; only Confirm sends
// anything onward. The Mac's page sends the same three calls (webviews `direct.ts` `uiSurfaceAction`).

extension AgentClientIntent {
    /// The Mac's acpmux methods (webviews `direct.ts`): `uiSurfaceAction`, `uiSurfaceConfirm`, `uiSurfaceCancel`.
    public static let uiSurfaceActionMethod = "_acpmux/ui_surface_action"
    public static let uiSurfaceConfirmMethod = "_acpmux/ui_surface_confirm"
    public static let uiSurfaceCancelMethod = "_acpmux/ui_surface_cancel"

    /// The JSON-RPC call an agent UI surface intent makes (its params without `sessionId`, which the
    /// source adds); nil for every other intent.
    public var uiSurfaceCall: (method: String, params: [String: JSONValue])? {
        switch self {
        case .uiSurfaceAction(let surfaceID, let actionID, let values):
            return (method: Self.uiSurfaceActionMethod,
                    params: ["surfaceId": .string(surfaceID), "actionId": .string(actionID), "values": .object(values)])
        case .uiSurfaceConfirm(let surfaceID, let requestID):
            return (method: Self.uiSurfaceConfirmMethod, params: ["surfaceId": .string(surfaceID), "requestId": .string(requestID)])
        case .uiSurfaceCancel(let surfaceID, let requestID):
            return (method: Self.uiSurfaceCancelMethod, params: ["surfaceId": .string(surfaceID), "requestId": .string(requestID)])
        default:
            return nil
        }
    }
}

/// Where a card's presses go. The chat's is ``UISurfaceSourceActions``; a preview or test hands its own.
@MainActor
protocol UISurfaceActions: AnyObject, Sendable {
    /// A button, approve, deny or submit: Rust's Pending for it, or nil (refused, or nothing to confirm).
    func action(surfaceId: String, actionId: String, values: [String: JSONValue]) async -> UISurface.Pending?
    /// Confirm on the pending strip: the only call that sends anything to the agent or a tool.
    func confirm(surfaceId: String, requestId: String)
    /// Cancel on the pending strip, or a value changed under it: Rust drops the request.
    func cancel(surfaceId: String, requestId: String)
}

/// The chat's actions: the intents go to the Mac on the link a permission answer takes
/// (``AgentSessionSource/uiSurfaceRequest(_:)``, acpmux `_acpmux/ui_surface_*`).
@MainActor
final class UISurfaceSourceActions: UISurfaceActions {
    private weak var source: (any AgentSessionSource)?

    init(source: any AgentSessionSource) {
        self.source = source
    }

    func action(surfaceId: String, actionId: String, values: [String: JSONValue]) async -> UISurface.Pending? {
        guard let source,
              let reply = await source.uiSurfaceRequest(.uiSurfaceAction(surfaceId: surfaceId, actionId: actionId, values: values))
        else { return nil }
        // The reply is the Pending itself, or wraps it (`{pending}`).
        return (try? (reply["pending"] ?? reply).decoded(as: UISurface.Pending.self))
    }

    func confirm(surfaceId: String, requestId: String) {
        guard let source else { return }
        Task { _ = await source.uiSurfaceRequest(.uiSurfaceConfirm(surfaceId: surfaceId, requestId: requestId)) }
    }

    func cancel(surfaceId: String, requestId: String) {
        guard let source else { return }
        Task { _ = await source.uiSurfaceRequest(.uiSurfaceCancel(surfaceId: surfaceId, requestId: requestId)) }
    }
}

/// A chat's surface cards' state: the field values each holds (the person's edits, by bind), the
/// Pending Rust answered an action with, and the requests already confirmed or cancelled. Kept by the
/// chat (``ChatRowContext``), so a card scrolled away and back keeps what was typed.
@MainActor
@Observable
final class UISurfaceHost {
    let actions: any UISurfaceActions
    private var edits: [String: [String: JSONValue]] = [:]
    private var answered: [String: UISurface.Pending] = [:]
    /// Requests the person confirmed or cancelled: a surface that still carries one shows no strip.
    private var settled: Set<String> = []
    /// Surfaces with an action on its way to the Mac.
    private(set) var waiting: Set<String> = []
    /// The actions each surface confirmed, by surface id (an approval says Approved or Denied).
    private(set) var confirmed: [String: Set<String>] = [:]
    /// Bumped when a strip opens, so the card announces it (VoiceOver).
    private(set) var pendingShown = 0

    init(actions: any UISurfaceActions) {
        self.actions = actions
    }

    /// The value the card holds under `key` (the person's edit, else what Rust last sent).
    func value(_ surface: UISurface, _ key: String, initial: JSONValue?) -> JSONValue? {
        edits[surface.surfaceId]?[key] ?? initial
    }

    /// Every value the card holds, by bind: what an action sends.
    func values(_ surface: UISurface) -> [String: JSONValue] {
        surface.initialValues.merging(edits[surface.surfaceId] ?? [:]) { _, edit in edit }
    }

    /// An edit. A changed value drops a request waiting for confirmation (DESIGN.md).
    func set(_ surface: UISurface, _ key: String, _ value: JSONValue) {
        guard edits[surface.surfaceId]?[key] != value else { return }
        edits[surface.surfaceId, default: [:]][key] = value
        if let open = pending(surface) { cancel(surface, open) }
    }

    /// The strip the card shows: Rust's answer to the last press, else the surface's own `pending`,
    /// unless the person already answered it.
    func pending(_ surface: UISurface) -> UISurface.Pending? {
        let shown = answered[surface.surfaceId] ?? surface.pending
        guard let shown, !settled.contains(shown.requestId) else { return nil }
        return shown
    }

    /// A press: sends the action id and the held values; Rust's Pending opens the strip.
    func press(_ surface: UISurface, _ action: UISurface.Action, extra: [String: JSONValue] = [:]) {
        let id = surface.surfaceId
        guard !waiting.contains(id) else { return }
        if let open = pending(surface) { cancel(surface, open) }
        waiting.insert(id)
        let held = self.values(surface).merging(extra) { _, new in new }
        Task {
            let pending = await self.actions.action(surfaceId: id, actionId: action.id, values: held)
            waiting.remove(id)
            if let pending {
                answered[id] = pending
                settled.remove(pending.requestId)
                pendingShown &+= 1
            }
        }
    }

    func confirm(_ surface: UISurface, _ pending: UISurface.Pending) {
        settled.insert(pending.requestId)
        answered[surface.surfaceId] = nil
        confirmed[surface.surfaceId, default: []].insert(pending.actionId)
        actions.confirm(surfaceId: surface.surfaceId, requestId: pending.requestId)
    }

    func cancel(_ surface: UISurface, _ pending: UISurface.Pending) {
        settled.insert(pending.requestId)
        answered[surface.surfaceId] = nil
        actions.cancel(surfaceId: surface.surfaceId, requestId: pending.requestId)
    }
}
