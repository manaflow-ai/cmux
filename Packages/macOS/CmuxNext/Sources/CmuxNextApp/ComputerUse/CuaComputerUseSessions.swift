import CmuxNextAgentActivity
import CmuxNextComputerUse
import Foundation

/// ``ComputerUseSessionControlling`` over the CUA host socket the helper runs
/// (`ComputerUseHelperDaemon.configuration`, which carries the host token user
/// operations need). While no helper runs, the reason comes from the phase
/// `computer_use.status` reports (``ComputerUseSetup``). A request that gets
/// no answer asks the helper's owner whether its process still exists
/// (`confirmRunning`, ``ComputerUseHelperDaemon/confirmRunning()``): a helper
/// that is gone starts again, and the reason says so instead of "did not answer".
@MainActor
final class CuaComputerUseSessions: ComputerUseSessionControlling {
    private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?
    private let phase: @MainActor () -> ComputerUseSetup.Phase
    private let confirmRunning: @MainActor () -> ComputerUseHelperDaemon.State

    init(configuration: @escaping @MainActor () -> AgentActivitySocketSource.Configuration?,
         phase: @escaping @MainActor () -> ComputerUseSetup.Phase,
         confirmRunning: @escaping @MainActor () -> ComputerUseHelperDaemon.State) {
        self.configuration = configuration
        self.phase = phase
        self.confirmRunning = confirmRunning
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
            switch confirmRunning() {
            case .running: throw ComputerUseSessionError.failed(ComputerUseSessionStrings.hostUnreachable)
            // The helper was gone; its owner is starting it again.
            case .off: throw ComputerUseSessionError.notRunning(ComputerUseSessionStrings.helperRestarting)
            case .unavailable, .failed: throw ComputerUseSessionError.notRunning(ComputerUseSessionStrings.helperNotRunning)
            }
        }
    }
}
