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
        await sendGestureSequence(events, totalDurationMilliseconds: nil)
    }

    func sendGestureSequence(
        _ events: [SimulatorPointerEvent],
        totalDurationMilliseconds: Int?
    ) async -> Bool {
        guard !events.isEmpty,
              events.count <= simulatorUIAutomationMaximumGestureEventCount else {
            return false
        }
        let interEventDelay: Duration
        if let totalDurationMilliseconds {
            guard (0...10_000).contains(totalDurationMilliseconds) else { return false }
            interEventDelay = .nanoseconds(
                events.count > 1
                    ? (Int64(totalDurationMilliseconds) * 1_000_000)
                        / Int64(events.count - 1)
                    : 0
            )
        } else {
            interEventDelay = simulatorIsTapSequence(events)
                ? .milliseconds(50)
                : .milliseconds(4)
        }
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

    func sendTouchSequence(
        _ events: [SimulatorPointerEvent],
        holdMilliseconds: Int
    ) async -> Bool {
        guard (1...2).contains(events.count),
              (0...10_000).contains(holdMilliseconds) else {
            return false
        }
        for (index, event) in events.enumerated() {
            guard send(event) else {
                _ = releaseInputs()
                return false
            }
            guard index == 0, events.count == 2, holdMilliseconds > 0 else { continue }
            do {
                try await sleeper.sleep(for: .milliseconds(holdMilliseconds))
            } catch {
                _ = releaseInputs()
                return false
            }
        }
        if events.count == 1, events[0].phase == .began {
            return lastPointerEvent != nil
        }
        return lastPointerEvent == nil
    }

    func sendKeyPresses(
        usages: [UInt32],
        pressDurationMilliseconds: Int,
        interKeyDelayMilliseconds: Int
    ) async -> Bool {
        guard !usages.isEmpty, usages.count <= 100,
              usages.allSatisfy({ $0 <= 255 }),
              (0...10_000).contains(pressDurationMilliseconds),
              (0...5_000).contains(interKeyDelayMilliseconds),
              heldKeys.isEmpty else {
            return false
        }
        for (index, usage) in usages.enumerated() {
            guard await sendAndWait(SimulatorKeyEvent(usage: usage, phase: .down)) else {
                await releaseHeldKeysAndWait()
                return false
            }
            do {
                if pressDurationMilliseconds > 0 {
                    try await sleeper.sleep(for: .milliseconds(pressDurationMilliseconds))
                }
            } catch {
                await releaseHeldKeysAndWait()
                return false
            }
            guard await sendAndWait(SimulatorKeyEvent(usage: usage, phase: .up)) else {
                await releaseHeldKeysAndWait()
                return false
            }
            guard index < usages.index(before: usages.endIndex),
                  interKeyDelayMilliseconds > 0 else {
                continue
            }
            do {
                try await sleeper.sleep(for: .milliseconds(interKeyDelayMilliseconds))
            } catch {
                await releaseHeldKeysAndWait()
                return false
            }
        }
        return heldKeys.isEmpty
    }

}

private func simulatorIsTapSequence(_ events: [SimulatorPointerEvent]) -> Bool {
    guard events.count == 2 else { return false }
    let down = events[0]
    let up = events[1]
    return down.phase == .began
        && up.phase == .ended
        && down.primary == up.primary
        && down.secondary == up.secondary
        && down.edge == up.edge
}
