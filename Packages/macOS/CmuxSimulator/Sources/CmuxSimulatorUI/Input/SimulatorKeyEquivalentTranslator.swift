import AppKit
import CmuxSimulator

struct SimulatorKeyEquivalentTranslator {
    private let keyMapper: SimulatorHIDKeyMapper

    init(keyMapper: SimulatorHIDKeyMapper) {
        self.keyMapper = keyMapper
    }

    func action(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        heldUsages: Set<UInt32> = []
    ) -> SimulatorKeyEquivalentAction? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return nil }
        guard let usage = keyMapper.usage(for: keyCode) else { return nil }
        let modifiers = modifierUsages(flags).filter { !heldUsages.contains($0) }
        var events = modifiers.map {
            SimulatorKeyEvent(usage: $0, phase: .down)
        }
        events.append(SimulatorKeyEvent(usage: usage, phase: .down))
        events.append(SimulatorKeyEvent(usage: usage, phase: .up))
        events.append(contentsOf: modifiers.reversed().map {
            SimulatorKeyEvent(usage: $0, phase: .up)
        })
        return .messages([.keySequence(events)])
    }

    private func modifierUsages(_ flags: NSEvent.ModifierFlags) -> [UInt32] {
        var usages: [UInt32] = []
        if flags.contains(.control) { usages.append(0xE0) }
        if flags.contains(.shift) { usages.append(0xE1) }
        if flags.contains(.option) { usages.append(0xE2) }
        if flags.contains(.command) { usages.append(0xE3) }
        return usages
    }
}

let simulatorKeyEquivalentTranslator = SimulatorKeyEquivalentTranslator(
    keyMapper: simulatorHIDKeyMapper
)
