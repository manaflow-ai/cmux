import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator HID partial-failure containment")
struct SimulatorHIDFailureContainmentTests {
    @Test("React Native reload unwinds every successful key down")
    @MainActor
    func reloadUnwindsPartialFailure() async {
        let script = HIDSendScript(outcomes: [true, true, false, true, true])
        let sleeper = RecordingHIDSleeper()
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: sleeper,
            keySenderOverride: { script.send(key: $0) }
        )

        #expect(!(await transport.reloadReactNative()))
        #expect(script.keyEvents == [
            SimulatorKeyEvent(usage: 0xE3, phase: .down),
            SimulatorKeyEvent(usage: 0x15, phase: .down),
            SimulatorKeyEvent(usage: 0x15, phase: .up),
            SimulatorKeyEvent(usage: 0x15, phase: .up),
            SimulatorKeyEvent(usage: 0xE3, phase: .up),
        ])
        #expect(sleeper.durations == [.milliseconds(30), .milliseconds(30)])
        #expect(transport.heldKeys.isEmpty)
    }

    @Test("Failed convenience-button up remains tracked until release")
    @MainActor
    func convenienceButtonFailedUpIsReleased() async {
        let script = HIDSendScript(outcomes: [true, false, true])
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: ImmediateHIDSleeper(),
            convenienceSenderOverride: { button, down in
                script.send(button: button, down: down)
            }
        )

        #expect(!(await transport.press(.home)))
        #expect(transport.heldConvenienceButtons.count == 1)
        #expect(transport.releaseInputs())
        #expect(transport.heldConvenienceButtons.isEmpty)
        #expect(script.buttonDirections == [true, false, false])
    }

    @Test("Cancelled convenience-button pacing releases the held button and fails")
    @MainActor
    func convenienceButtonCancellationReleasesHold() async {
        let script = HIDSendScript(outcomes: [true, true])
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: RecordingHIDSleeper(throwOnCall: 1),
            convenienceSenderOverride: { button, down in
                script.send(button: button, down: down)
            }
        )

        #expect(!(await transport.press(.home)))
        #expect(transport.heldConvenienceButtons.isEmpty)
        #expect(script.buttonDirections == [true, false])
    }

    @Test("Cancelled system-gesture pacing sends a touch cancellation and fails")
    @MainActor
    func systemGestureCancellationReleasesTouch() async {
        var events: [SimulatorPointerEvent] = []
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: RecordingHIDSleeper(throwOnCall: 1),
            pointerSenderOverride: { event in
                events.append(event)
                return true
            }
        )

        #expect(!(await transport.press(.swipeHome)))
        #expect(events.map(\.phase) == [.began, .cancelled])
        #expect(transport.lastPointerEvent == nil)
    }

    @Test("Two-event taps use an iPadOS-compatible hold duration")
    @MainActor
    func tapUsesNativeHoldDuration() async {
        let sleeper = RecordingHIDSleeper()
        var events: [SimulatorPointerEvent] = []
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: sleeper,
            pointerSenderOverride: { event in
                events.append(event)
                return true
            }
        )
        let point = SimulatorPoint(x: 0.6, y: 0.525)
        let tap = [
            SimulatorPointerEvent(phase: .began, primary: point),
            SimulatorPointerEvent(phase: .ended, primary: point),
        ]

        #expect(await transport.sendGestureSequence(tap))
        #expect(events == tap)
        #expect(sleeper.durations == [.milliseconds(50)])
    }

    @Test("App switcher sends one paced double-Home sequence")
    @MainActor
    func appSwitcherUsesDoubleHome() async {
        let script = HIDSendScript(outcomes: [true, true, true, true])
        let sleeper = RecordingHIDSleeper()
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: sleeper,
            convenienceSenderOverride: { button, down in
                script.send(button: button, down: down)
            }
        )

        #expect(await transport.press(.appSwitcher))
        #expect(script.buttonDirections == [true, false, true, false])
        #expect(sleeper.durations == [
            .milliseconds(50),
            .milliseconds(50),
            .milliseconds(50),
        ])
        #expect(transport.heldConvenienceButtons.isEmpty)
    }

    @Test("Text transmission preserves order and uses cancellable pacing")
    @MainActor
    func textTransmissionPacing() async throws {
        let script = HIDSendScript(outcomes: [true, true])
        let sleeper = RecordingHIDSleeper()
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: sleeper,
            keySenderOverride: { script.send(key: $0) }
        )
        let events = [
            SimulatorKeyEvent(usage: 4, phase: .down),
            SimulatorKeyEvent(usage: 4, phase: .up),
        ]

        #expect(await transport.sendTextSequence(try .init(characterCount: 1, events: events)))
        #expect(script.keyEvents == events)
        #expect(sleeper.durations == [.milliseconds(4), .milliseconds(4), .milliseconds(50)])
    }

    @Test("Cancellation unwinds a key held during paced transmission")
    @MainActor
    func textTransmissionCancellation() async throws {
        let script = HIDSendScript(outcomes: [true, true])
        let sleeper = RecordingHIDSleeper(throwOnCall: 1)
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: sleeper,
            keySenderOverride: { script.send(key: $0) }
        )
        let sequence = try SimulatorTextInputSequence(characterCount: 1, events: [
            SimulatorKeyEvent(usage: 4, phase: .down),
            SimulatorKeyEvent(usage: 4, phase: .up),
        ])

        #expect(!(await transport.sendTextSequence(sequence)))
        #expect(script.keyEvents == [
            SimulatorKeyEvent(usage: 4, phase: .down),
            SimulatorKeyEvent(usage: 4, phase: .up),
        ])
        #expect(transport.heldKeys.isEmpty)
    }

    @Test("Long repeated text preserves every HID event before the local drain")
    @MainActor
    func longRepeatedTextTransmission() async throws {
        let sequence = try SimulatorUSKeyboardTextEncoder().encode(
            String(repeating: "Ab9!", count: 128)
        )
        let script = HIDSendScript(outcomes: Array(
            repeating: true,
            count: sequence.events.count
        ))
        let sleeper = RecordingHIDSleeper()
        let drain = TransmissionDrainProbe()
        let transport = SimulatorHIDTransport(
            frameworkLoader: SimulatorFrameworkLoader(environment: ["DEVELOPER_DIR": "/tmp"]),
            sleeper: sleeper,
            keySenderOverride: { script.send(key: $0) },
            transmissionDrainerOverride: { drain.record(); return true }
        )

        #expect(await transport.sendTextSequence(sequence))
        #expect(script.keyEvents == sequence.events)
        #expect(drain.count == 1)
        #expect(sleeper.durations.count == sequence.events.count + 1)
        #expect(sleeper.durations.last == .milliseconds(50))
    }
}
