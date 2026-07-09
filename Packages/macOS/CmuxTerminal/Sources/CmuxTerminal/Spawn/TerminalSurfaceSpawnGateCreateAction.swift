import Foundation

enum TerminalSurfaceSpawnGateCreateAction: Equatable {
    case proceed(TerminalSurfaceSpawnGrant?)
    case deny(reason: String, request: TerminalSurfaceSpawnGateRequest)
    case stop
}
