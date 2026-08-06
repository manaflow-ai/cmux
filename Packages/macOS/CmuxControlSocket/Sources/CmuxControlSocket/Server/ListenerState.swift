internal import Dispatch
internal import CmuxSettings

/// Main-actor transport resources and listener state.
struct ListenerState {
    var socketPath: String
    var boundSocketPathOwnership: BoundSocketPathOwnership = .none
    var serverSocket: Int32 = -1
    var isRunning = false
    var acceptLoopAlive = false
    var activeAcceptLoopGeneration: UInt64 = 0
    var nextAcceptLoopGeneration: UInt64 = 0
    var pendingAcceptLoopRearmGeneration: UInt64?
    var reservedStartupSocketPath: String?
    var reservedStartupSocketPathCanReplaceRefusedSocket = false
    var listenerState: ListenerStartupState = .idle(generation: 0)
    var socketPathLockFD: Int32 = -1
    var listenerReadSource: (any DispatchSourceRead)?
    var listenerReadSourceSuspended = false
    var socketPathMonitorSource: (any DispatchSourceFileSystemObject)?
    var accessMode: SocketControlMode = .cmuxOnly
    var configuredPreferredSocketPath: String?
}
