import CmuxSimulator

/// Tracks only live input that the pane accepted for worker delivery.
struct SimulatorAdmittedInputStateMachine {
    private var activePointer: SimulatorPointerEvent?
    private var heldKeys: Set<UInt32> = []
    private var heldButtons: Set<SimulatorHIDButtonUsage> = []

    mutating func record(_ message: SimulatorWorkerInbound) {
        switch message {
        case let .pointer(event):
            switch event.phase {
            case .began, .moved:
                activePointer = event
            case .ended, .cancelled:
                activePointer = nil
            }
        case let .key(event):
            switch event.phase {
            case .down:
                heldKeys.insert(event.usage)
            case .up:
                heldKeys.remove(event.usage)
            }
        case let .hidButton(event):
            switch event.phase {
            case .down:
                heldButtons.insert(event.button)
            case .up:
                heldButtons.remove(event.button)
            }
        case .releaseInputs:
            reset()
        default:
            break
        }
    }

    mutating func releaseAll() -> [SimulatorWorkerInbound] {
        var messages: [SimulatorWorkerInbound] = []
        if let activePointer {
            messages.append(.pointer(SimulatorPointerEvent(
                phase: .cancelled,
                primary: activePointer.primary,
                secondary: activePointer.secondary,
                edge: activePointer.edge
            )))
        }
        messages.append(contentsOf: heldKeys.sorted().map {
            .key(SimulatorKeyEvent(usage: $0, phase: .up))
        })
        messages.append(contentsOf: heldButtons
            .sorted { ($0.page, $0.usage) < ($1.page, $1.usage) }
            .map {
                .hidButton(SimulatorHIDButtonEvent(button: $0, phase: .up))
            })
        reset()
        return messages
    }

    private mutating func reset() {
        activePointer = nil
        heldKeys.removeAll(keepingCapacity: true)
        heldButtons.removeAll(keepingCapacity: true)
    }
}
