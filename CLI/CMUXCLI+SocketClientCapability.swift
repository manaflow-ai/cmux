import CmuxControlSocket
import Foundation

extension SocketClient {
    func capabilityWrappedCommand(
        _ command: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard !isRelayBacked,
              let capability = environment[SocketClientCapabilityEnvelope.environmentKey],
              let envelope = SocketClientCapabilityEnvelope(capability: capability) else {
            return command
        }
        return envelope.wrap(command)
    }
}
