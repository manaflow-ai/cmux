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
        /// The parked agent could not be resumed, so the saved terminal history
        /// is shown as context and the user can start a fresh session.
        case parkedTranscriptUnavailable
        /// The parked agent's resume command was rejected; the saved terminal
        /// history remains available as context in the restored pane.
        case parkedResumeUnavailable
    }

    var state: State?
}
