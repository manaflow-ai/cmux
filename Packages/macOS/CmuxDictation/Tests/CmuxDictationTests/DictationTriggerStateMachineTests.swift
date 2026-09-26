import Testing
@testable import CmuxDictation

/// Gesture classification for the fn-key trigger, on synthetic timelines.
@Suite
struct DictationTriggerStateMachineTests {
    private let config = DictationShortcutConfiguration(doubleTapInterval: 0.45, holdThreshold: 0.8)

    @Test("Single tap produces nothing")
    mutating func singleTapIsInert() {
        var machine = DictationTriggerStateMachine(configuration: config)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.0) == nil)
        #expect(machine.handle(isDown: false, isBareFunction: true, timestamp: 1.05) == nil)
    }

    @Test("Two presses inside the interval are a double tap")
    mutating func doubleTapFires() {
        var machine = DictationTriggerStateMachine(configuration: config)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.0) == nil)
        #expect(machine.handle(isDown: false, isBareFunction: true, timestamp: 1.05) == nil)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.25) == .doubleTap)
        // Release of the double-tap press is inert.
        #expect(machine.handle(isDown: false, isBareFunction: true, timestamp: 1.30) == nil)
    }

    @Test("Presses outside the interval are not a double tap")
    mutating func slowRepeatIsNotDoubleTap() {
        var machine = DictationTriggerStateMachine(configuration: config)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.0) == nil)
        #expect(machine.handle(isDown: false, isBareFunction: true, timestamp: 1.05) == nil)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.50) == nil)
    }

    @Test("A modified press breaks the double-tap window")
    mutating func modifiedPressBreaksWindow() {
        var machine = DictationTriggerStateMachine(configuration: config)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.0) == nil)
        #expect(machine.handle(isDown: false, isBareFunction: true, timestamp: 1.05) == nil)
        // Shift held for the next tap: never dictation, and the window resets.
        #expect(machine.handle(isDown: true, isBareFunction: false, timestamp: 1.20) == nil)
        #expect(machine.handle(isDown: false, isBareFunction: false, timestamp: 1.25) == nil)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.30) == nil)
    }

    @Test("Hold pair: beginHold promotes the press, release ends it")
    mutating func holdPairFires() {
        var machine = DictationTriggerStateMachine(configuration: config)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.0) == nil)
        let promoted = machine.beginHold()
        #expect(promoted)
        #expect(machine.isHoldActive)
        #expect(machine.handle(isDown: false, isBareFunction: true, timestamp: 1.9) == .holdEnd)
        #expect(!machine.isHoldActive)
    }

    @Test("beginHold is refused without an active promotable press")
    mutating func beginHoldRefusals() {
        var machine = DictationTriggerStateMachine(configuration: config)
        // No press at all.
        let promoted = machine.beginHold()
        #expect(!promoted)
        // A double-tap press cannot become a hold.
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.0) == nil)
        #expect(machine.handle(isDown: false, isBareFunction: true, timestamp: 1.05) == nil)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.25) == .doubleTap)
        let promotedAfterDoubleTap = machine.beginHold()
        #expect(!promotedAfterDoubleTap)
    }

    @Test("Hold release then tap does not pair as double tap")
    mutating func holdDoesNotSeedDoubleTap() {
        var machine = DictationTriggerStateMachine(configuration: config)
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 1.0) == nil)
        let promoted = machine.beginHold()
        #expect(promoted)
        #expect(machine.handle(isDown: false, isBareFunction: true, timestamp: 1.9) == .holdEnd)
        // Immediate next press is a fresh gesture, not a double-tap second press.
        #expect(machine.handle(isDown: true, isBareFunction: true, timestamp: 2.0) == nil)
    }
}
