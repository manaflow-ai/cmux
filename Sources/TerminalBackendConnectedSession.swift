import CmuxTerminalBackend
import CmuxTerminalBackendService

/// One trusted readiness proof paired with the connection it fenced.
struct TerminalBackendConnectedSession: Sendable {
    let readiness: BackendServiceReadiness
    let session: any TerminalBackendSessionServing
    let snapshot: TopologySnapshot?
}
