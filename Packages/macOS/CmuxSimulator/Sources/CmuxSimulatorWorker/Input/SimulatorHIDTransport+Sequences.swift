import CmuxSimulator

extension SimulatorHIDTransport {
    func sendTextSequence(_ sequence: SimulatorTextInputSequence) async -> Bool {
        guard heldKeys.isEmpty else { return false }
        for event in sequence.events {
            guard await sendAndWait(event) else {
                await releaseHeldKeysAndWait()
                return false
            }
            do {
                // dtuhidd has no event acknowledgement. Intentional pacing
                // prevents same-turn key events from being coalesced by iOS.
                try await sleeper.sleep(for: .milliseconds(4))
            } catch {
                await releaseHeldKeysAndWait()
                return false
            }
        }
        let transmissionDrained: Bool
        if let transmissionDrainerOverride {
            transmissionDrained = await transmissionDrainerOverride()
        } else if let modernTransport {
            transmissionDrained = await modernTransport.drainLocalTransmission()
        } else {
            transmissionDrained = true
        }
        guard transmissionDrained else {
            await releaseHeldKeysAndWait()
            return false
        }
        do {
            try await sleeper.sleep(for: .milliseconds(50))
        } catch {
            await releaseHeldKeysAndWait()
            return false
        }
        return heldKeys.isEmpty
    }

    func sendGestureSequence(_ events: [SimulatorPointerEvent]) async -> Bool {
        guard !events.isEmpty, events.count <= 256 else { return false }
        let interEventDelay: Duration = Self.isTapSequence(events)
            ? .milliseconds(50)
            : .milliseconds(4)
        for (index, event) in events.enumerated() {
            guard send(event) else {
                _ = releaseInputs()
                return false
            }
            guard index < events.index(before: events.endIndex) else { continue }
            do {
                try await sleeper.sleep(for: interEventDelay)
            } catch {
                _ = releaseInputs()
                return false
            }
        }
        return lastPointerEvent == nil
    }

    private static func isTapSequence(_ events: [SimulatorPointerEvent]) -> Bool {
        guard events.count == 2 else { return false }
        let down = events[0]
        let up = events[1]
        return down.phase == .began
            && up.phase == .ended
            && down.primary == up.primary
            && down.secondary == up.secondary
            && down.edge == up.edge
    }
}
