import Foundation

/// One text or selection-reference segment from the composed user instruction.
enum BrowserDesignModePromptPayloadSegment: Encodable {
    case text(String)
    case selection(Int)

    private enum CodingKeys: String, CodingKey {
        case text
        case selection
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .selection(let index):
            try container.encode(index, forKey: .selection)
        }
    }
}
