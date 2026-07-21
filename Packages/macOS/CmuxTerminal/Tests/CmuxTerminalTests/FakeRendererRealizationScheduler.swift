@testable import CmuxTerminal

@MainActor
final class FakeRendererRealizationScheduler: TerminalRendererRealizationScheduling {
    private(set) var scheduledPassCount = 0

    func scheduleImmediatePass() {
        scheduledPassCount += 1
    }
}
