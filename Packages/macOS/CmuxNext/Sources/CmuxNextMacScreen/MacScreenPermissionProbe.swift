import CmuxNextWakeups
import Foundation

/// Reads permissions in the same responsible process context as the screen host, without prompting.
nonisolated struct MacScreenPermissionProbe {
    private struct Reply: Decodable {
        let screen_recording: Bool
        let accessibility: Bool
    }

    func read() async throws -> (screen: Bool, control: Bool) {
        guard let binary = MacScreenRdProcess.binary else { throw CocoaError(.fileNoSuchFile) }
        let result = try await AsyncProcess().run(ProcessRequest(binary, ["rd", "permissions"], timeout: .seconds(5)))
        guard result.succeeded else { throw CocoaError(.executableRuntimeMismatch) }
        let reply = try JSONDecoder().decode(Reply.self, from: result.output)
        return (reply.screen_recording, reply.accessibility)
    }
}
