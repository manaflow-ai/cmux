import Foundation

/// The immutable identifier tmux assigns for the lifetime of one session.
struct LocalTmuxSessionIdentity: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        let bytes = rawValue.utf8
        guard bytes.count >= 2,
              bytes.first == 0x24,
              bytes.dropFirst().allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let identity = Self(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid tmux session identity"
            )
        }
        self = identity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
