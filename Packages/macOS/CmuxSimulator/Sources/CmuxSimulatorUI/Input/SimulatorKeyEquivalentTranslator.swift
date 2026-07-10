import AppKit
import CmuxSimulator

enum SimulatorKeyEquivalentAction: Equatable {
    case messages([SimulatorWorkerInbound])
}

struct SimulatorKeyEquivalentTranslator {
    private let keyMapper: SimulatorHIDKeyMapper

    init(keyMapper: SimulatorHIDKeyMapper) {
        self.keyMapper = keyMapper
    }

    func action(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> SimulatorKeyEquivalentAction? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return nil }
        guard let usage = keyMapper.usage(for: keyCode) else { return nil }
        let modifiers = modifierUsages(flags)
        var messages = modifiers.map {
            SimulatorWorkerInbound.key(SimulatorKeyEvent(usage: $0, phase: .down))
        }
        messages.append(.key(SimulatorKeyEvent(usage: usage, phase: .down)))
        messages.append(.key(SimulatorKeyEvent(usage: usage, phase: .up)))
        messages.append(contentsOf: modifiers.reversed().map {
            SimulatorWorkerInbound.key(SimulatorKeyEvent(usage: $0, phase: .up))
        })
        return .messages(messages)
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
