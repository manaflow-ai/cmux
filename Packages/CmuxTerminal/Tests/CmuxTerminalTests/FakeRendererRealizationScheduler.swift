@testable import CmuxTerminal

final class FakeRendererRealizationScheduler: TerminalRendererRealizationScheduling {
    @MainActor
    func scheduleImmediatePass() {}
}
