import CmuxSimulator
import Foundation

private let simulatorScrollWheelEdgeMargin = 0.08

private func simulatorScrollWheelEventIsValid(_ event: SimulatorScrollWheelEvent) -> Bool {
    event.anchor.x.isFinite && event.anchor.y.isFinite
        && event.deltaX.isFinite && event.deltaY.isFinite
        && (event.deltaX != 0 || event.deltaY != 0)
}

private func simulatorClampedScrollPoint(_ point: SimulatorPoint) -> SimulatorPoint {
    SimulatorPoint(
        x: min(max(point.x, simulatorScrollWheelEdgeMargin), 1 - simulatorScrollWheelEdgeMargin),
        y: min(max(point.y, simulatorScrollWheelEdgeMargin), 1 - simulatorScrollWheelEdgeMargin)
    )
}

private func simulatorScrollPointIsAtEdge(_ point: SimulatorPoint) -> Bool {
    point.x <= simulatorScrollWheelEdgeMargin || point.x >= 1 - simulatorScrollWheelEdgeMargin
        || point.y <= simulatorScrollWheelEdgeMargin || point.y >= 1 - simulatorScrollWheelEdgeMargin
}

@MainActor
final class SimulatorScrollWheelController {
    typealias Sender = @MainActor (SimulatorPointerEvent) -> Bool
    typealias Completion = @MainActor (UUID) -> Void

    private let sender: Sender
    private let sleeper: any SimulatorHIDSleeping
    private let completion: Completion
    private var active = false
    private var finger = SimulatorPoint(x: 0.5, y: 0.5)
    private var anchor = SimulatorPoint(x: 0.5, y: 0.5)
    private var idleTask: Task<Void, Never>?
    private var idleGeneration: UUID?
    private var latestEventIdentifier: UUID?

    init(
        sender: @escaping Sender,
        sleeper: any SimulatorHIDSleeping,
        completion: @escaping Completion
    ) {
        self.sender = sender
        self.sleeper = sleeper
        self.completion = completion
    }

    func send(_ event: SimulatorScrollWheelEvent) async -> Bool {
        guard simulatorScrollWheelEventIsValid(event) else {
            completion(event.id)
            return false
        }
        latestEventIdentifier = event.id
        idleTask?.cancel()
        idleTask = nil
        idleGeneration = nil
        let eventAnchor = simulatorClampedScrollPoint(event.anchor)
        if !active {
            anchor = eventAnchor
            finger = eventAnchor
            guard await begin() else {
                finishBurst()
                return false
            }
        }

        var next = SimulatorPoint(x: finger.x + event.deltaX, y: finger.y + event.deltaY)
        if simulatorScrollPointIsAtEdge(next) {
            guard sender(SimulatorPointerEvent(phase: .ended, primary: finger)) else {
                _ = cancel()
                return false
            }
            active = false
            anchor = eventAnchor
            finger = eventAnchor
            guard await begin() else {
                finishBurst()
                return false
            }
            next = SimulatorPoint(x: finger.x + event.deltaX, y: finger.y + event.deltaY)
        }
        finger = simulatorClampedScrollPoint(next)
        guard sender(SimulatorPointerEvent(phase: .moved, primary: finger)) else {
            _ = cancel()
            return false
        }
        scheduleIdleEnd()
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        idleTask?.cancel()
        idleTask = nil
        idleGeneration = nil
        if active,
           !sender(SimulatorPointerEvent(phase: .cancelled, primary: finger)) {
            active = false
            return false
        }
        active = false
        finishBurst()
        return true
    }

    private func begin() async -> Bool {
        guard sender(SimulatorPointerEvent(phase: .began, primary: finger)) else { return false }
        active = true
        do {
            try await sleeper.sleep(for: .milliseconds(8))
            return true
        } catch {
            _ = cancel()
            return false
        }
    }

    private func scheduleIdleEnd() {
        let generation = UUID()
        idleGeneration = generation
        let sleeper = self.sleeper
        idleTask = Task { @MainActor [weak self] in
            do {
                try await sleeper.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self, self.idleGeneration == generation, self.active else { return }
            let ended = self.sender(SimulatorPointerEvent(phase: .ended, primary: self.finger))
            self.active = false
            self.idleTask = nil
            self.idleGeneration = nil
            if ended { self.finishBurst() }
        }
    }

    private func finishBurst() {
        guard let latestEventIdentifier else { return }
        self.latestEventIdentifier = nil
        completion(latestEventIdentifier)
    }

}
