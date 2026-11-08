import CmuxSimulator

struct SimulatorHeldHIDButtonState: Sendable {
    private(set) var buttons: Set<SimulatorHIDButtonUsage> = []

    mutating func record(_ event: SimulatorHIDButtonEvent) {
        switch event.phase {
        case .down:
            buttons.insert(event.button)
        case .up:
            buttons.remove(event.button)
        }
    }

    mutating func takeReleaseEvents() -> [SimulatorHIDButtonEvent] {
        defer { buttons.removeAll(keepingCapacity: true) }
        return buttons
            .sorted {
                ($0.page, $0.usage) < ($1.page, $1.usage)
            }
            .map { SimulatorHIDButtonEvent(button: $0, phase: .up) }
    }
}
