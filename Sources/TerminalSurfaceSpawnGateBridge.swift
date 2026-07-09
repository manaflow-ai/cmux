import CmuxHooks
import CmuxTerminal
import Foundation
#if DEBUG
import CMUXDebugLog
#endif

final class TerminalSurfaceSpawnGateBridge: TerminalSurfaceSpawnGating {
    private let configState: @Sendable () -> CmuxHooksConfigState
    private let gate: SpawnHookGate

    init(
        configState: @escaping @Sendable () -> CmuxHooksConfigState,
        gate: SpawnHookGate
    ) {
        self.configState = configState
        self.gate = gate
    }

    @MainActor
    func requiresGate() -> Bool {
        switch configState() {
        case .absent:
            return false
        case .broken:
            return true
        case .loaded(let config):
            return config.preSpawn?.enabled == true
        }
    }

    @MainActor
    func resolveSpawn(_ request: TerminalSurfaceSpawnGateRequest) async -> TerminalSurfaceSpawnGateResolution {
        let hookRequest = SpawnHookRequest(
            command: request.command,
            workingDirectory: request.workingDirectory,
            environmentAdditions: request.environmentAdditions,
            surfaceId: request.surfaceId.uuidString,
            workspaceId: request.workspaceId.uuidString,
            source: request.source,
            isRespawn: request.isRespawn
        )
        switch await gate.evaluate(hookRequest) {
        case .proceed(let grant):
            return .proceed(TerminalSurfaceSpawnGrant(
                command: grant.command,
                workingDirectory: grant.workingDirectory,
                environmentOverrides: grant.environmentOverrides
            ))
        case .deny(let reason):
            return .deny(reason: reason)
        }
    }

    @MainActor
    func deniedSpawnMessage(reason: String) -> String {
        let format = String(
            localized: "hooks.preSpawn.denied.message",
            defaultValue: "cmux blocked this terminal from starting:\n%@"
        )
        return String(format: format, reason)
    }

    @MainActor
    func spawnDenied(reason: String, request: TerminalSurfaceSpawnGateRequest) {
        CmuxEventBus.shared.publish(
            name: "hook.spawn.denied",
            category: "hook",
            source: "hooks.pre_spawn",
            workspaceId: request.workspaceId.uuidString,
            surfaceId: request.surfaceId.uuidString,
            payload: [
                "reason": reason,
                "command_preview": request.command ?? NSNull()
            ]
        )
#if DEBUG
        logDebugEvent(
            "hooks preSpawn denied surface=\(request.surfaceId.uuidString.prefix(5)) " +
            "workspace=\(request.workspaceId.uuidString.prefix(5))"
        )
#endif
    }
}
