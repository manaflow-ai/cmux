import Foundation
import CmuxControlSocket

extension TerminalController {
    /// Startup-only dependency projection for synchronous socket workers.
    func configurePluginRuntime(_ runtime: CmuxPluginRuntime) {
        pluginRuntimeSlot.withLock { configuredRuntime in configuredRuntime = runtime }
    }

    /// Reads the injected runtime without a main-actor hop from socket workers.
    nonisolated func pluginRuntimeSnapshot() -> CmuxPluginRuntime? {
        pluginRuntimeSlot.withLock { $0 }
    }

    /// Applies the plugin transport policy before ordinary socket authorization.
    nonisolated func admitPluginConnection(
        processID: pid_t?,
        isEventStreamRequest: Bool,
        writer: ControlClientAsyncWriter,
        runtime: CmuxPluginRuntime?
    ) async -> Bool? {
        let policy = runtime?.socketPeerPolicy(
            forProcess: processID,
            isEventStreamRequest: isEventStreamRequest
        ) ?? .standard
        guard policy != .denied else {
            _ = await writer.writeAll(Data((Self.socketClientAccessDeniedResponse + "\n").utf8))
            return nil
        }
        return policy == .pluginEventStream
    }
}
