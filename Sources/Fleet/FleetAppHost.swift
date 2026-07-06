import CMUXAgentLaunch
import CmuxFleet
import Foundation

/// Owns the app-side Fleet engine composition.
///
/// The control socket and workstream tap reach Fleet through this host so the
/// engine is instantiated only when the Fleet socket domain is used.
@MainActor
final class FleetAppHost {
    /// The shared app composition host.
    static let shared = FleetAppHost()

    private var engineStorage: FleetEngine?

    /// The lazily constructed Fleet engine.
    var engine: FleetEngine {
        if let engineStorage {
            return engineStorage
        }
        let engine = FleetEngine(dependencies: FleetEngineDependencies(
            actuator: FleetAppActuator(),
            world: FleetAppWorldReader(),
            timers: FleetAppTimers(),
            processWatcher: FleetAppProcessWatcher(),
            persistence: FleetAppPersistence(),
            now: { Date() },
            debugLog: { message in
#if DEBUG
                cmuxDebugLog(message)
#else
                _ = message
#endif
            }
        ))
        engineStorage = engine
        return engine
    }

    /// Forwards one workstream hook event when Fleet already owns the event workspace.
    ///
    /// Events are dropped without instantiating the engine while Fleet is unused.
    func handleWorkstreamEvent(_ event: WorkstreamEvent) {
        guard let engine = engineStorage,
              let workspaceID = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceID.isEmpty,
              engine.hasTask(workspaceID: workspaceID)
        else { return }
        engine.noteWorkstreamHook(
            workspaceID: workspaceID,
            sessionID: event.sessionId,
            pid: event.ppid.map(Int32.init),
            kind: event.hookEventName.fleetHookKind,
            at: event.receivedAt
        )
    }

    private init() {}
}

extension WorkstreamEvent.HookEventName {
    /// The Fleet supervision hook kind for this workstream hook.
    var fleetHookKind: FleetHookKind {
        switch self {
        case .sessionStart:
            .sessionStart
        case .stop:
            .stop
        case .sessionEnd:
            .sessionEnd
        case .permissionRequest, .askUserQuestion, .exitPlanMode:
            .blockingRequest
        case .userPromptSubmit:
            .promptSubmit
        case .preToolUse, .postToolUse, .todoWrite:
            .toolUse
        case .notification:
            .notification
        case .preCompact, .postCompact, .subagentStart, .subagentStop:
            .other
        }
    }
}
