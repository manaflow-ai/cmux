import Foundation
@testable import CmuxTerminal

final class FakeHibernationRecorder: AgentHibernationRecording {
    @MainActor
    func recordTerminalInput(workspaceId: UUID, panelId: UUID) {}
}
