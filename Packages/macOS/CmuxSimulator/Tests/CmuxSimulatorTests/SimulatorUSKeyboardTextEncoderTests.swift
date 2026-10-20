import Foundation
import Testing
@testable import CmuxSimulator

@Suite("US-keyboard text encoder")
struct SimulatorUSKeyboardTextEncoderTests {
    @Test("ASCII mappings preserve order and balanced Shift phases")
    func fullMapping() throws {
        let source = "aA1!0)-_=+[]{}\\|;:'\"`~,<.>/? \n\t"
        let sequence = try SimulatorUSKeyboardTextEncoder().encode(source)

        #expect(sequence.characterCount == source.count)
        #expect(sequence.events.prefix(6) == [
            SimulatorKeyEvent(usage: 0x04, phase: .down),
            SimulatorKeyEvent(usage: 0x04, phase: .up),
            SimulatorKeyEvent(usage: 0xE1, phase: .down),
            SimulatorKeyEvent(usage: 0x04, phase: .down),
            SimulatorKeyEvent(usage: 0x04, phase: .up),
            SimulatorKeyEvent(usage: 0xE1, phase: .up),
        ])

        var held: Set<UInt32> = []
        for event in sequence.events {
            switch event.phase {
            case .down:
                #expect(held.insert(event.usage).inserted)
            case .up:
                #expect(held.remove(event.usage) != nil)
            }
        }
        #expect(held.isEmpty)
    }

    @Test("Every printable US ASCII character encodes")
    func printableASCII() throws {
        let source = String((0x20...0x7E).compactMap(Unicode.Scalar.init).map(Character.init))
        let sequence = try SimulatorUSKeyboardTextEncoder().encode(source)
        #expect(sequence.characterCount == 95)
    }

    @Test("Every US key maps to its exact HID usage and Shift phase")
    func exactMappings() throws {
        for offset in 0..<26 {
            let lower = Character(Unicode.Scalar(0x61 + offset)!)
            try expect(lower, usage: UInt32(0x04 + offset), shifted: false)
            let upper = Character(Unicode.Scalar(0x41 + offset)!)
            try expect(upper, usage: UInt32(0x04 + offset), shifted: true)
        }
        for (character, usage) in zip("1234567890", 0x1E...0x27) {
            try expect(character, usage: UInt32(usage), shifted: false)
        }
        let punctuation: [(Character, UInt32, Bool)] = [
            ("!", 0x1E, true), ("@", 0x1F, true), ("#", 0x20, true),
            ("$", 0x21, true), ("%", 0x22, true), ("^", 0x23, true),
            ("&", 0x24, true), ("*", 0x25, true), ("(", 0x26, true),
            (")", 0x27, true), ("-", 0x2D, false), ("_", 0x2D, true),
            ("=", 0x2E, false), ("+", 0x2E, true), ("[", 0x2F, false),
            ("{", 0x2F, true), ("]", 0x30, false), ("}", 0x30, true),
            ("\\", 0x31, false), ("|", 0x31, true), (";", 0x33, false),
            (":", 0x33, true), ("'", 0x34, false), ("\"", 0x34, true),
            ("`", 0x35, false), ("~", 0x35, true), (",", 0x36, false),
            ("<", 0x36, true), (".", 0x37, false), (">", 0x37, true),
            ("/", 0x38, false), ("?", 0x38, true), (" ", 0x2C, false),
            ("\n", 0x28, false), ("\t", 0x2B, false),
        ]
        for (character, usage, shifted) in punctuation {
            try expect(character, usage: usage, shifted: shifted)
        }
    }

    @Test("Unsupported Unicode is rejected before a sequence exists")
    func rejectsUnicode() {
        #expect(throws: SimulatorTextInputEncodingError.unsupportedScalar(
            value: 0x1F642,
            scalarIndex: 1
        )) {
            try SimulatorUSKeyboardTextEncoder().encode("a🙂")
        }
    }

    @Test("Oversize input is rejected before expansion")
    func rejectsOversize() {
        let source = String(repeating: "a", count: SimulatorTextInputSequence.maximumUTF8ByteCount + 1)
        #expect(throws: SimulatorTextInputEncodingError.tooLong(
            actualUTF8ByteCount: source.utf8.count,
            maximumUTF8ByteCount: SimulatorTextInputSequence.maximumUTF8ByteCount
        )) {
            try SimulatorUSKeyboardTextEncoder().encode(source)
        }
    }

    @Test("Maximum input receives a bounded length-aware completion deadline")
    func maximumInputDeadline() throws {
        let source = String(repeating: "a", count: SimulatorTextInputSequence.maximumUTF8ByteCount)
        let sequence = try SimulatorUSKeyboardTextEncoder().encode(source)
        #expect(sequence.events.count == SimulatorTextInputSequence.maximumUTF8ByteCount * 2)
        #expect(sequence.completionTimeoutSeconds > 100)
        #expect(sequence.completionTimeoutSeconds <= 120)
    }

    @Test("CRLF and standalone CR each map to one Enter")
    func carriageReturnNormalization() throws {
        let enter = [
            SimulatorKeyEvent(usage: 0x28, phase: .down),
            SimulatorKeyEvent(usage: 0x28, phase: .up),
        ]
        let crlf = try SimulatorUSKeyboardTextEncoder().encode("\r\n")
        #expect(crlf.characterCount == 1)
        #expect(crlf.events == enter)

        let lone = try SimulatorUSKeyboardTextEncoder().encode("a\rb")
        #expect(lone.characterCount == 3)
        #expect(lone.events == [
            SimulatorKeyEvent(usage: 0x04, phase: .down),
            SimulatorKeyEvent(usage: 0x04, phase: .up),
            SimulatorKeyEvent(usage: 0x28, phase: .down),
            SimulatorKeyEvent(usage: 0x28, phase: .up),
            SimulatorKeyEvent(usage: 0x05, phase: .down),
            SimulatorKeyEvent(usage: 0x05, phase: .up),
        ])

        let carriageReturnOnly = try SimulatorUSKeyboardTextEncoder().encode("\r")
        #expect(carriageReturnOnly.characterCount == 1)
        #expect(carriageReturnOnly.events == enter)
    }

    @Test("Decoded sequences must remain balanced")
    func rejectsMalformedDecodedSequence() throws {
        let malformed = #"{"characterCount":1,"events":[{"usage":4,"phase":"down"}]}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SimulatorTextInputSequence.self, from: Data(malformed.utf8))
        }
        let missingEvents = #"{"characterCount":1,"events":[]}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                SimulatorTextInputSequence.self,
                from: Data(missingEvents.utf8)
            )
        }
    }

    private func expect(
        _ character: Character,
        usage: UInt32,
        shifted: Bool
    ) throws {
        let events = try SimulatorUSKeyboardTextEncoder().encode(String(character)).events
        if shifted {
            #expect(events == [
                SimulatorKeyEvent(usage: 0xE1, phase: .down),
                SimulatorKeyEvent(usage: usage, phase: .down),
                SimulatorKeyEvent(usage: usage, phase: .up),
                SimulatorKeyEvent(usage: 0xE1, phase: .up),
            ])
        } else {
            #expect(events == [
                SimulatorKeyEvent(usage: usage, phase: .down),
                SimulatorKeyEvent(usage: usage, phase: .up),
            ])
        }
    }
}
