import Foundation

/// Encodes text into deterministic USB HID usage events for a US keyboard.
public struct SimulatorUSKeyboardTextEncoder: Sendable {
    private let leftShiftUsage: UInt32

    /// Creates an encoder for the standard USB left-shift usage.
    public init(leftShiftUsage: UInt32 = 0xE1) {
        self.leftShiftUsage = leftShiftUsage
    }

    /// Validates the complete string before returning any input events.
    public func encode(_ text: String) throws -> SimulatorTextInputSequence {
        let byteCount = text.utf8.count
        guard byteCount > 0 else {
            throw SimulatorTextInputEncodingError.empty
        }
        guard byteCount <= SimulatorTextInputSequence.maximumUTF8ByteCount else {
            throw SimulatorTextInputEncodingError.tooLong(
                actualUTF8ByteCount: byteCount,
                maximumUTF8ByteCount: SimulatorTextInputSequence.maximumUTF8ByteCount
            )
        }

        let scalars = Array(text.unicodeScalars)
        var mappings: [(usage: UInt32, shifted: Bool)] = []
        mappings.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\r" {
                mappings.append((usage: 0x28, shifted: false))
                index += 1
                if index < scalars.count, scalars[index] == "\n" {
                    index += 1
                }
                continue
            }
            guard let mapping = mapping(for: scalar) else {
                throw SimulatorTextInputEncodingError.unsupportedScalar(
                    value: scalar.value,
                    scalarIndex: index
                )
            }
            mappings.append(mapping)
            index += 1
        }

        var events: [SimulatorKeyEvent] = []
        events.reserveCapacity(mappings.count * 2)
        for mapping in mappings {
            if mapping.shifted {
                events.append(SimulatorKeyEvent(usage: leftShiftUsage, phase: .down))
            }
            events.append(SimulatorKeyEvent(usage: mapping.usage, phase: .down))
            events.append(SimulatorKeyEvent(usage: mapping.usage, phase: .up))
            if mapping.shifted {
                events.append(SimulatorKeyEvent(usage: leftShiftUsage, phase: .up))
            }
        }
        return try SimulatorTextInputSequence(
            characterCount: mappings.count,
            events: events
        )
    }

    private func mapping(for scalar: Unicode.Scalar) -> (usage: UInt32, shifted: Bool)? {
        let value = scalar.value
        if value >= 0x61, value <= 0x7A { // a...z
            return (0x04 + value - 0x61, false)
        }
        if value >= 0x41, value <= 0x5A { // A...Z
            return (0x04 + value - 0x41, true)
        }
        if value >= 0x31, value <= 0x39 { // 1...9
            return (0x1E + value - 0x31, false)
        }
        if value == 0x30 { return (0x27, false) }

        switch scalar {
        case "\n": return (0x28, false)
        case "\t": return (0x2B, false)
        case " ": return (0x2C, false)
        case "-": return (0x2D, false)
        case "_": return (0x2D, true)
        case "=": return (0x2E, false)
        case "+": return (0x2E, true)
        case "[": return (0x2F, false)
        case "{": return (0x2F, true)
        case "]": return (0x30, false)
        case "}": return (0x30, true)
        case "\\": return (0x31, false)
        case "|": return (0x31, true)
        case ";": return (0x33, false)
        case ":": return (0x33, true)
        case "'": return (0x34, false)
        case "\"": return (0x34, true)
        case "`": return (0x35, false)
        case "~": return (0x35, true)
        case ",": return (0x36, false)
        case "<": return (0x36, true)
        case ".": return (0x37, false)
        case ">": return (0x37, true)
        case "/": return (0x38, false)
        case "?": return (0x38, true)
        case "!": return (0x1E, true)
        case "@": return (0x1F, true)
        case "#": return (0x20, true)
        case "$": return (0x21, true)
        case "%": return (0x22, true)
        case "^": return (0x23, true)
        case "&": return (0x24, true)
        case "*": return (0x25, true)
        case "(": return (0x26, true)
        case ")": return (0x27, true)
        default: return nil
        }
    }
}
