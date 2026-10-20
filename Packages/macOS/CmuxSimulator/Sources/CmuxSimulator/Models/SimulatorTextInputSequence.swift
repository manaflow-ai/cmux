import Foundation

/// A bounded, balanced sequence of USB keyboard events for one text insertion.
public struct SimulatorTextInputSequence: Codable, Equatable, Sendable {
    /// Maximum accepted source-text size, measured before HID expansion.
    public static let maximumUTF8ByteCount = 4_096
    /// Maximum expanded event count. A shifted character needs four events.
    public static let maximumEventCount = maximumUTF8ByteCount * 4
    /// The source character count used for action reporting.
    public let characterCount: Int
    /// Keyboard events in the exact order the worker must deliver them.
    public let events: [SimulatorKeyEvent]

    /// Deadline shared by the socket receipt and bounded worker sequence.
    public var completionTimeoutSeconds: TimeInterval {
        min(120, max(10, 10 + (Double(events.count) * 0.012)))
    }

    /// Creates a bounded sequence and verifies that every key is released.
    public init(characterCount: Int, events: [SimulatorKeyEvent]) throws {
        guard characterCount >= 0 else {
            throw SimulatorTextInputEncodingError.malformedSequence
        }
        guard characterCount <= Self.maximumUTF8ByteCount,
              events.count <= Self.maximumEventCount else {
            throw SimulatorTextInputEncodingError.tooLong(
                actualUTF8ByteCount: characterCount,
                maximumUTF8ByteCount: Self.maximumUTF8ByteCount
            )
        }

        var heldUsages: Set<UInt32> = []
        for event in events {
            switch event.phase {
            case .down:
                guard heldUsages.insert(event.usage).inserted else {
                    throw SimulatorTextInputEncodingError.malformedSequence
                }
            case .up:
                guard heldUsages.remove(event.usage) != nil else {
                    throw SimulatorTextInputEncodingError.malformedSequence
                }
            }
        }
        let shapeIsValid = (characterCount == 0 && events.isEmpty)
            || (characterCount > 0 && !events.isEmpty)
        guard heldUsages.isEmpty, shapeIsValid else {
            throw SimulatorTextInputEncodingError.malformedSequence
        }

        self.characterCount = characterCount
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case characterCount
        case events
    }

    /// Decodes and validates a bounded, balanced sequence.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let characterCount = try container.decode(Int.self, forKey: .characterCount)
        let events = try container.decode([SimulatorKeyEvent].self, forKey: .events)
        do {
            try self.init(characterCount: characterCount, events: events)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .events,
                in: container,
                debugDescription: "Invalid bounded Simulator text-input sequence: \(error)"
            )
        }
    }
}
