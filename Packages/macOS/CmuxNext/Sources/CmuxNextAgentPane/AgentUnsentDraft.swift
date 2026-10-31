import Foundation

/// A persisted draft boundary, including an empty clear/send tombstone. Old text-only values
/// decode as generation zero; malformed generations make the file unreadable, never fresh.
nonisolated struct AgentUnsentDraft: Codable, Equatable, Sendable {
    static let maximumGeneration = 9_007_199_254_740_991 // Number.MAX_SAFE_INTEGER in the webview
    let text: String
    let generation: Int

    static func valid(_ generation: Int) -> Bool { (0...maximumGeneration).contains(generation) }

    init(text: String, generation: Int) {
        self.text = text
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey { case text, generation }

    init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text: legacy, generation: 0)
            return
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let text = try fields.decode(String.self, forKey: .text)
        let generation = try fields.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        guard Self.valid(generation) else {
            throw DecodingError.dataCorruptedError(forKey: .generation, in: fields, debugDescription: "Draft generation is not a nonnegative safe integer")
        }
        self.init(text: text, generation: generation)
    }
}
