import Foundation

enum TerminalSurfaceSpawnGateState: Equatable {
    case idle
    case pending
    case resolved(TerminalSurfaceSpawnGateResolution)
}
