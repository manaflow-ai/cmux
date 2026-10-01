import CMUXAgentLaunch
import Foundation
import Observation

/// Native restore status stays with the terminal when it moves between containers.
@MainActor
@Observable
final class AgentRestoreRecoveryPresentation {
    enum State: Equatable {
        case checking
        case liveOwner(kind: String, processID: Int)
        case writerLock(candidates: [CodexWriterProcessInspector.Candidate])
    }

    var state: State?
}
