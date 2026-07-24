import CmuxSimulator
@testable import CmuxSimulatorWorker

@MainActor
final class HIDSendScript {
    private var outcomes: [Bool]
    private(set) var keyEvents: [SimulatorKeyEvent] = []
    private(set) var buttonDirections: [Bool] = []

    init(outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    func send(key event: SimulatorKeyEvent) -> Bool {
        keyEvents.append(event)
        return nextOutcome()
    }

    func send(button: SimulatorConvenienceButton, down: Bool) -> Bool {
        buttonDirections.append(down)
        return nextOutcome()
    }

    private func nextOutcome() -> Bool {
        outcomes.isEmpty ? false : outcomes.removeFirst()
    }
}
