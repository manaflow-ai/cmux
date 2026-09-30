import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class RemoteRelayNarrowingContext: ControlCommandContext {
    let workspaceID = UUID()
    let surfaceID = UUID()
    let status: JSONValue = .object([
        "enabled": .bool(true),
        "state": .string("connected"),
        "connected": .bool(true),
        "destination": .string("builder@example.internal"),
        "local_proxy_port": .int(61_234),
        "proxy": .object(["state": .string("ready"), "port": .int(61_235)]),
        "daemon": .object(["remote_path": .string("/home/builder/.cmux/bin/cmuxd-remote")]),
    ])
    private(set) var replyShapeWire: String??

    func controlRemoteRelayDispatchError(method: String, params: [String: JSONValue]) -> ControlCallResult? { nil }

    func controlWorkspaceRemoteStatus(workspaceID: UUID) -> ControlWorkspaceRemoteResolution {
        .resolved(windowID: nil, workspaceID: workspaceID, remoteStatus: status)
    }

    func controlWorkspaceRemoteTerminalSessionLaunching(
        workspaceID: UUID,
        surfaceID: UUID,
        terminalLifecycleID: UUID,
        attemptID: UUID
    ) -> ControlWorkspaceRemoteTerminalSessionConnectedResolution {
        .resolved(windowID: nil, workspaceID: workspaceID, remoteStatus: status)
    }

    func controlWorkspaceRemoteTerminalSessionConnected(
        workspaceID: UUID,
        surfaceID: UUID,
        authority: ControlWorkspaceRemoteTerminalAuthority,
        attemptID: UUID,
        commitLease: (any ControlRemotePTYLifecycleCommitLease)?
    ) -> ControlWorkspaceRemoteTerminalSessionConnectedResolution {
        .resolved(windowID: nil, workspaceID: workspaceID, remoteStatus: status)
    }

    func controlWorkspaceRemoteTerminalSessionEnd(
        workspaceID: UUID,
        surfaceID: UUID,
        relayPort: Int?,
        terminalLifecycleID: UUID?,
        sessionID: String?,
        lifecycleID: String?,
        lifecycleOnly: Bool
    ) -> ControlWorkspaceRemoteTerminalSessionEndResolution {
        .resolved(windowID: nil, workspaceID: workspaceID, remoteStatus: status)
    }

    func controlNotificationCreateForTarget(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String,
        replyShapeWire: String?
    ) -> ControlNotificationTargetedDeliveryResolution {
        self.replyShapeWire = .some(replyShapeWire)
        return .delivered(workspaceID: workspaceID, surfaceID: surfaceID, windowID: nil, notificationID: UUID())
    }
}

@MainActor
@Suite("Remote relay narrowing: coordinator payloads")
struct ControlCommandCoordinatorRemoteRelayNarrowingTests {
    private static let relayStatusKeys: Set<String> = ["enabled", "state", "connected"]

    private func request(_ method: String, _ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func relayed(_ params: [String: JSONValue], _ context: RemoteRelayNarrowingContext) -> [String: JSONValue] {
        params.merging(["_cmux_remote_workspace_id": .string(context.workspaceID.uuidString)]) { $1 }
    }

    private func remoteKeys(_ result: ControlCallResult?) -> Set<String>? {
        guard case .ok(.object(let payload))? = result, case .object(let remote)? = payload["remote"] else { return nil }
        return Set(remote.keys)
    }

    private func lifecycleRequests(_ context: RemoteRelayNarrowingContext) -> [(String, [String: JSONValue])] {
        let target: [String: JSONValue] = [
            "workspace_id": .string(context.workspaceID.uuidString),
            "surface_id": .string(context.surfaceID.uuidString),
        ]
        let terminal = target.merging([
            "terminal_lifecycle_id": .string(UUID().uuidString),
            "attempt_id": .string(UUID().uuidString),
        ]) { $1 }
        return [
            ("workspace.remote.status", ["workspace_id": .string(context.workspaceID.uuidString)]),
            ("workspace.remote.terminal_session_launching", terminal),
            ("workspace.remote.terminal_session_connected", terminal.merging(["relay_port": .int(64_007)]) { $1 }),
            ("workspace.remote.terminal_session_end", terminal.merging(["relay_port": .int(64_007)]) { $1 }),
        ]
    }

    private func dispatch(
        _ coordinator: ControlCommandCoordinator,
        _ context: RemoteRelayNarrowingContext,
        _ method: String,
        _ params: [String: JSONValue]
    ) -> ControlCallResult? {
        switch method {
        case "workspace.remote.terminal_session_launching", "workspace.remote.terminal_session_connected":
            coordinator.handleSocketWorkerV2(request(method, params), context: context)
        default:
            coordinator.handle(request(method, params))
        }
    }

    @Test func relayedRemoteStatusCarriesOnlyConnectionState() throws {
        let context = RemoteRelayNarrowingContext()
        let coordinator = ControlCommandCoordinator(context: context)
        for (method, params) in lifecycleRequests(context) {
            let keys = remoteKeys(dispatch(coordinator, context, method, relayed(params, context)))
            #expect(keys == Self.relayStatusKeys, "\(method) returned \(String(describing: keys))")
        }
    }

    @Test func localRemoteStatusKeepsTheFullPayload() throws {
        let context = RemoteRelayNarrowingContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let full = try #require(remoteKeys(.ok(.object(["remote": context.status]))))
        for (method, params) in lifecycleRequests(context) {
            let keys = remoteKeys(dispatch(coordinator, context, method, params))
            #expect(keys == full, "\(method) returned \(String(describing: keys))")
        }
    }

    @Test func relayedNotificationDropsTheReplyShape() throws {
        let context = RemoteRelayNarrowingContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(request("notification.create_for_target", relayed(notification(context), context)))
        guard case .ok? = result else {
            Issue.record("relayed notification was not delivered: \(String(describing: result))")
            return
        }
        #expect(context.replyShapeWire == .some(nil))
    }

    @Test func localNotificationKeepsTheReplyShape() throws {
        let context = RemoteRelayNarrowingContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(request("notification.create_for_target", notification(context)))
        guard case .ok? = result else {
            Issue.record("local notification was not delivered: \(String(describing: result))")
            return
        }
        #expect(context.replyShapeWire == .some("text"))
    }

    private func notification(_ context: RemoteRelayNarrowingContext) -> [String: JSONValue] {
        [
            "workspace_id": .string(context.workspaceID.uuidString),
            "surface_id": .string(context.surfaceID.uuidString),
            "title": .string("Build finished"),
            "reply_shape": .string("text"),
        ]
    }
}
