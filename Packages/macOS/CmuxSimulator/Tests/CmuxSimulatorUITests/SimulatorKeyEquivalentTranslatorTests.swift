import AppKit
import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator key equivalents")
struct SimulatorKeyEquivalentTranslatorTests {
    @Test("Command shortcuts forward ordered modifier and key pairs")
    func commandShortcut() {
        let action = simulatorKeyEquivalentTranslator.action(
            keyCode: 8,
            modifierFlags: [.command]
        )

        #expect(action == .messages([
            .keySequence([
                SimulatorKeyEvent(usage: 0xE3, phase: .down),
                SimulatorKeyEvent(usage: 0x06, phase: .down),
                SimulatorKeyEvent(usage: 0x06, phase: .up),
                SimulatorKeyEvent(usage: 0xE3, phase: .up),
            ]),
        ]))
    }

    @Test("Configured host shortcuts fall back to ordered guest keys when unbound")
    func hostShortcutFallback() {
        let action = simulatorKeyEquivalentTranslator.action(
            keyCode: 4,
            modifierFlags: [.command, .shift]
        )

        #expect(action == .messages([
            .keySequence([
                SimulatorKeyEvent(usage: 0xE1, phase: .down),
                SimulatorKeyEvent(usage: 0xE3, phase: .down),
                SimulatorKeyEvent(usage: 0x0B, phase: .down),
                SimulatorKeyEvent(usage: 0x0B, phase: .up),
                SimulatorKeyEvent(usage: 0xE3, phase: .up),
                SimulatorKeyEvent(usage: 0xE1, phase: .up),
            ]),
        ]))
    }

    @Test("A physically held Command key remains held after the guest chord")
    func heldCommandModifierIsNotSynthesized() {
        let action = simulatorKeyEquivalentTranslator.action(
            keyCode: 8,
            modifierFlags: [.command],
            heldUsages: [0xE3]
        )

        #expect(action == .messages([.keySequence([
            SimulatorKeyEvent(usage: 0x06, phase: .down),
            SimulatorKeyEvent(usage: 0x06, phase: .up),
        ])]))
    }

    @Test("Mapped keypad keys preserve generic Command-chord forwarding")
    func keypadCommandShortcut() {
        let action = simulatorKeyEquivalentTranslator.action(
            keyCode: 69,
            modifierFlags: [.command, .option]
        )

        #expect(action == .messages([
            .keySequence([
                SimulatorKeyEvent(usage: 0xE2, phase: .down),
                SimulatorKeyEvent(usage: 0xE3, phase: .down),
                SimulatorKeyEvent(usage: 0x57, phase: .down),
                SimulatorKeyEvent(usage: 0x57, phase: .up),
                SimulatorKeyEvent(usage: 0xE3, phase: .up),
                SimulatorKeyEvent(usage: 0xE2, phase: .up),
            ]),
        ]))
    }

    @Test("Non-command events stay in the normal responder chain")
    func nonCommandEvent() {
        #expect(simulatorKeyEquivalentTranslator.action(
            keyCode: 8,
            modifierFlags: []
        ) == nil)
    }
}
