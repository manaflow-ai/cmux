import CmuxSimulator

struct SimulatorChromeButtonStateMachine {
    private(set) var heldButtons: Set<SimulatorHIDButtonUsage> = []

    mutating func press(
        _ button: SimulatorDeviceChromeProfile.Button
    ) -> [SimulatorWorkerInbound] {
        guard let usage = button.hidUsage,
              heldButtons.insert(usage).inserted else { return [] }
        return [.hidButton(SimulatorHIDButtonEvent(button: usage, phase: .down))]
    }

    mutating func release(
        _ button: SimulatorDeviceChromeProfile.Button
    ) -> [SimulatorWorkerInbound] {
        guard let usage = button.hidUsage,
              heldButtons.remove(usage) != nil else { return [] }
        return [.hidButton(SimulatorHIDButtonEvent(button: usage, phase: .up))]
    }

    mutating func releaseAll() -> [SimulatorWorkerInbound] {
        defer { heldButtons.removeAll(keepingCapacity: true) }
        return heldButtons
            .sorted { ($0.page, $0.usage) < ($1.page, $1.usage) }
            .map {
                .hidButton(SimulatorHIDButtonEvent(button: $0, phase: .up))
            }
    }

    func isHeld(_ button: SimulatorDeviceChromeProfile.Button) -> Bool {
        button.hidUsage.map(heldButtons.contains) ?? false
    }
}
