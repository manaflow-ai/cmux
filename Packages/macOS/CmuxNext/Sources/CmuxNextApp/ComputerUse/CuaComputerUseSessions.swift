import CmuxNextAgentActivity
import Foundation

/// ``ComputerUseSessionControlling`` over the CUA host socket the helper runs
/// (`ComputerUseHelperDaemon.configuration`, which carries the host token user
/// operations need). While no helper runs, the reason comes from the phase
/// `computer_use.status` reports (``ComputerUseSetup``).
@MainActor
final class CuaComputerUseSessions: ComputerUseSessionControlling {
    private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?
    private let phase: @MainActor () -> ComputerUseSetup.Phase

    init(configuration: @escaping @MainActor () -> AgentActivitySocketSource.Configuration?,
         phase: @escaping @MainActor () -> ComputerUseSetup.Phase) {
        self.configuration = configuration
        self.phase = phase
    }

    func liveSessions() async throws -> [ComputerUseLiveSession] {
        ComputerUseLiveSession.live(from: try await send("activity_sessions_list", ["status": "live"]))
    }

    func stop(_ id: String) async throws {
        _ = try await send("activity_session_stop", ["id": id])
    }

    private func send(_ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard let configuration = configuration() else {
            throw ComputerUseSessionError.notRunning(ComputerUseSessionStrings.notRunning(phase()))
        }
        do {
            return try await CuaSocketClient(configuration: configuration).send(method, args, deadline: .seconds(5))
        } catch AgentActivitySourceError.refused(let message) {
            throw ComputerUseSessionError.failed(ComputerUseSessionStrings.hostRefused(message))
        } catch {
            throw ComputerUseSessionError.failed(ComputerUseSessionStrings.hostUnreachable)
        }
    }
}
