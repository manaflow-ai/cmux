internal import Foundation

/// One OSC sequence condition, including its introducer and comparison mode.
public struct CmuxAgentOSCSequenceRule: Codable, Equatable, Hashable, Sendable {
    /// OSC bytes, including an ESC-] or C1 introducer.
    public var sequence: String
    /// How the sequence is compared with captured OSC data.
    public var mode: CmuxAgentOSCMatchMode

    /// Creates an OSC condition.
    public init(sequence: String, mode: CmuxAgentOSCMatchMode = .contains) {
        self.sequence = sequence
        self.mode = mode
    }

    /// Decodes either a shorthand string or an options object.
    ///
    /// - Parameter decoder: Decoder positioned at an OSC string or object.
    /// - Throws: ``DecodingError`` when the value has an unsupported shape.
    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self.init(sequence: value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sequence: try container.decode(String.self, forKey: .sequence),
            mode: try container.decodeIfPresent(CmuxAgentOSCMatchMode.self, forKey: .mode) ?? .contains
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, mode
    }
}
