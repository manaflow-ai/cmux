import CmuxNextDaemon
import Foundation

/// Mutations that have a registry action run that action: the same handler
/// the keyboard, menu, palette, and `cmux action run` use (shared-path
/// rule). Compat only translates old refs to action targets and shapes the
/// old response.
extension CompatService {
    /// Runs `id` on the main actor through the bounded work queue, then
    /// awaits the daemon work its handler started (`ActionRegistry.track`),
    /// so the reply comes after the effect exists. The router's request
    /// deadline bounds the wait.
    func runAction(_ id: String, target: ControlTargetRef? = nil, arguments: [String: ControlValue] = [:],
                   call: CompatCall) async throws {
        try await runAction(id, target: target, arguments: arguments, connection: call.control.connection,
                            method: call.method, deadline: call.control.deadline)
    }

    /// `runAction` for v1 verbs, which have no `ControlCall`.
    func runAction(_ id: String, target: ControlTargetRef? = nil, arguments: [String: ControlValue] = [:],
                   connection: ControlConnectionID, method: String, deadline: ContinuousClock.Instant) async throws {
        guard let router else { throw CompatErrors.stopped }
        var request = ControlActionRequest(actionID: id)
        request.target = target
        request.arguments = arguments
        let executor = router.executor
        let run = try await router.workQueue.run(connection: connection, method: method, deadline: deadline) {
            executor.performActionTracked(request)
        }
        switch run.outcome {
        case .ran:
            break
        case .refused(let reason):
            throw ControlError(code: "unavailable", message: "\(id): \(reason)", data: ["action": .string(id), "reason": .string(reason)])
        case .unknownAction, .notBound:
            throw CompatErrors.unsupported(ControlStrings.format("control.error.actionNoHandler", "the %@ action has no handler in this build", id), method: method)
        case .unavailable, .disabled:
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionNotAvailableNow", "%@ is not available right now", id), data: ["action": .string(id)])
        case .confirmationRequired:
            throw ControlRouter.confirmationRequired(id)
        }
        let failure = await ControlRouter.firstFailure(of: run.work)
        // The handler's daemon replies are in: later reads wait for their
        // events on every session (an action may write to a remote one).
        await noteWriteEverywhere()
        if let failure { throw ControlRouter.workError(failure, action: id, method: method) }
    }
}

extension CompatWorld {
    /// The surface in `after` that `before` lacked (the newest when several).
    func createdSurface(since before: CompatWorld, in workspaceUUID: String? = nil) -> Surface? {
        let known = Set(before.surfaces.keys)
        let fresh = surfaces.values.filter { !known.contains($0.uuid) && (workspaceUUID == nil || $0.workspaceUUID == workspaceUUID) }
        return fresh.max { $0.handle.rawValue < $1.handle.rawValue }
    }

    /// The workspace `before` lacked, on `session` (nil: home).
    func createdWorkspace(since before: CompatWorld, session: String? = nil) -> Workspace? {
        let known = Set(before.workspaces.map(\.uuid))
        return workspaces.last { !known.contains($0.uuid) && $0.sessionID == session }
    }
}

/// Action target refs for world objects (the App's model ids).
enum CompatTargets {
    static func tab(_ surface: CompatWorld.Surface) -> ControlTargetRef { ControlTargetRef(kind: "tab", id: surface.modelID) }
    static func pane(_ pane: CompatWorld.Pane) -> ControlTargetRef { ControlTargetRef(kind: "pane", id: pane.modelID) }
    static func workspace(_ workspace: CompatWorld.Workspace) -> ControlTargetRef {
        ControlTargetRef(kind: "workspace", id: workspace.modelID)
    }
}
