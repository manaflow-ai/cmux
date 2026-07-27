import CmuxSimulator
import Foundation

extension SimulatorWorkerCoordinator {
    func performInteractiveAction(_ action: SimulatorInteractiveAction) async -> Bool {
        let succeeded: Bool
        let name: String
        let summary: String
        switch action {
        case let .gesture(events):
            succeeded = await hid?.sendGestureSequence(events) == true
            gestureStart = nil
            gestureUsesTwoFingers = false
            name = "gesture"
            summary = "events:\(events.count)"
        case let .timedGesture(events, durationMilliseconds):
            succeeded = await hid?.sendGestureSequence(
                events,
                totalDurationMilliseconds: durationMilliseconds
            ) == true
            gestureStart = nil
            gestureUsesTwoFingers = false
            name = "timed_gesture"
            summary = "events:\(events.count),duration_ms:\(durationMilliseconds)"
        case let .touch(events, holdMilliseconds):
            succeeded = await hid?.sendTouchSequence(
                events,
                holdMilliseconds: holdMilliseconds
            ) == true
            name = "touch"
            summary = "events:\(events.count),hold_ms:\(holdMilliseconds)"
        case let .keyPresses(usages, pressDurationMilliseconds, interKeyDelayMilliseconds):
            succeeded = await hid?.sendKeyPresses(
                usages: usages,
                pressDurationMilliseconds: pressDurationMilliseconds,
                interKeyDelayMilliseconds: interKeyDelayMilliseconds
            ) == true
            name = "key_presses"
            summary = "keys:\(usages.count)"
        case let .keyChord(modifiers, key):
            let events = modifiers.map {
                SimulatorKeyEvent(usage: $0, phase: .down)
            } + [
                SimulatorKeyEvent(usage: key, phase: .down),
                SimulatorKeyEvent(usage: key, phase: .up),
            ] + modifiers.reversed().map {
                SimulatorKeyEvent(usage: $0, phase: .up)
            }
            succeeded = await hid?.sendPacedKeySequence(events) == true
            name = "key_chord"
            summary = "modifiers:\(modifiers.count),key:\(key)"
        case let .typeText(sequence):
            succeeded = await hid?.sendTextSequence(sequence) == true
            name = "type_text"
            summary = "characters:\(sequence.characterCount)"
        case let .hardwareButton(button):
            succeeded = await hid?.press(button) == true
            name = "button"
            summary = button.rawValue
        case let .hardwareButtonHold(button, durationMilliseconds):
            succeeded = await hid?.press(
                button,
                durationMilliseconds: durationMilliseconds
            ) == true
            name = "button"
            summary = "\(button.rawValue),duration_ms:\(durationMilliseconds)"
        case let .rotate(orientation):
            succeeded = hid?.rotate(orientation) == true
            if succeeded { framebuffer?.setOrientation(orientation) }
            name = "rotate"
            summary = orientation.rawValue
        case let .coreAnimation(diagnostic, enabled):
            succeeded = hid?.setCoreAnimationDiagnostic(diagnostic, enabled: enabled) == true
            name = "core_animation_diagnostic"
            summary = "\(diagnostic.rawValue):\(enabled)"
        case .memoryWarning:
            succeeded = hid?.simulateMemoryWarning() == true
            name = "memory_warning"
            summary = "simulate"
        }
        if !succeeded {
            sendUnavailableFailure(action: name, detail: "The Simulator action is unavailable.")
        }
        emitAction(name, summary: summary, succeeded: succeeded)
        return succeeded
    }
}
