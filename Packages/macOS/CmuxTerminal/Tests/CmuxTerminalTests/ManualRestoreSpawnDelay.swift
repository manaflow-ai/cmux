@testable import CmuxTerminal

@MainActor
final class ManualRestoreSpawnDelay: TerminalSurfaceRestoreSpawnDelayCancelling {
    func cancel() {}
}
