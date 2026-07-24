public import CMUXMobileCore
import CmuxMobileRPC
public import Foundation

public enum MobileTerminalSceneActivationError: Error, Equatable, Sendable {
    case unavailable
}

extension MobileShellComposite {
    /// Whether this exact connection can mount the canonical semantic renderer.
    public var usesTerminalSemanticScenes: Bool {
        terminalSceneCoordinator != nil
            && !terminalSemanticScenesDisabledForConnection
            && connectionState == .connected
            && activeRoute?.kind == .iroh
            && supportedHostCapabilities.contains(Self.terminalSemanticSceneCapability)
    }

    /// Falls back to the compatibility renderer after bounded scene recovery.
    ///
    /// The disable is scoped to this connection generation. A later reconnect
    /// negotiates semantic scenes again instead of persisting one transient GPU
    /// or transport failure as a product setting.
    public func disableTerminalSemanticScenesForCurrentConnection() {
        guard !terminalSemanticScenesDisabledForConnection else { return }
        terminalSemanticScenesDisabledForConnection = true
        deactivateAllTerminalScenes()
    }

    /// Opens one geometry-fenced scene and serially backpressures its consumer.
    public func activateTerminalScene(
        _ scene: MobileTerminalSceneRequest,
        consume: @escaping @Sendable (MobileTerminalSceneEnvelope) async throws -> Bool,
        finished: @escaping @Sendable (
            _ token: UUID,
            _ termination: MobileTerminalSceneTermination
        ) async -> Void
    ) async throws -> UUID {
        guard usesTerminalSemanticScenes,
              let terminalSceneCoordinator,
              let activeRoute,
              let activeTicket else {
            throw MobileTerminalSceneActivationError.unavailable
        }
        let request = CmxByteTransportRequest(
            route: activeRoute,
            expectedPeerDeviceID: activeTicket.macDeviceID,
            authorizationMode: .transportAdmission
        )
        let lifecycleID = terminalSceneLifecycleID
        let token = try await terminalSceneCoordinator.activate(.init(
            request: request,
            scene: scene,
            lifecycleID: lifecycleID,
            consume: consume,
            finished: finished
        ))
        guard terminalSceneLifecycleID == lifecycleID,
              usesTerminalSemanticScenes else {
            await terminalSceneCoordinator.deactivate(
                surfaceID: scene.surfaceID,
                token: token
            )
            throw MobileTerminalSceneActivationError.unavailable
        }
        return token
    }

    /// Closes only the matching presentation, preserving a newer same-surface mount.
    public func deactivateTerminalScene(surfaceID: String, token: UUID) async {
        await terminalSceneCoordinator?.deactivate(
            surfaceID: surfaceID,
            token: token
        )
    }

    func deactivateAllTerminalScenes() {
        guard let terminalSceneCoordinator else { return }
        let lifecycleID = terminalSceneLifecycleID
        terminalSceneLifecycleID = UUID()
        Task {
            await terminalSceneCoordinator.deactivateAll(
                lifecycleID: lifecycleID
            )
        }
    }
}
