import CmuxMobileRPC
import Foundation

extension MobileShellComposite {
    /// A `mobile.terminal.replay` response decoded away from the main actor.
    struct DecodedTerminalReplayResponse: Sendable {
        /// The decoded response, or `nil` when the payload was malformed.
        let payload: MobileTerminalReplayResponse?
        /// The decoded raw byte tail carried by ``MobileTerminalReplayResponse/dataBase64``.
        let bytes: Data?
        /// The decoded VT snapshot carried by ``MobileTerminalReplayResponse/snapshotBase64``.
        let snapshotBytes: Data?
    }

    /// Decodes one replay response (JSON plus base64 tails) on the global
    /// concurrent executor instead of the caller's actor.
    ///
    /// Replay responses carry full render-grid snapshots and base64 VT
    /// snapshot/byte tails; decoding them inline on `@MainActor` blocked the
    /// run loop for the whole payload, and under replay storms those blocks
    /// accumulated into watchdog-fatal hangs (CMUXTERM-MACOS-3CX6, 3D1S,
    /// 3D6T, 3DFD). Callers must re-validate their in-flight and connection
    /// guards after this suspension, exactly like any other await on those
    /// paths.
    nonisolated static func decodeTerminalReplayResponseOffMain(
        _ data: Data
    ) async -> DecodedTerminalReplayResponse {
        let decodeTask = Task.detached(priority: .userInitiated) {
            let payload = try? MobileTerminalReplayResponse.decode(data)
            return DecodedTerminalReplayResponse(
                payload: payload,
                bytes: payload?.dataBase64.flatMap { Data(base64Encoded: $0) },
                snapshotBytes: payload?.snapshotBase64.flatMap { Data(base64Encoded: $0) }
            )
        }
        return await withTaskCancellationHandler(
            operation: { await decodeTask.value },
            onCancel: { decodeTask.cancel() }
        )
    }
}
