import Foundation

struct WorkspaceShareAccessRequest: Decodable, Equatable, Sendable {
    let connectionId: String?
    let userId: String
    let email: String
    let displayName: String
    let color: Int
    let requestedAt: Int64

    private enum CodingKeys: String, CodingKey {
        case connectionId
        case userId
        case email
        case displayName
        case color
        case requestedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionId = try container.decodeIfPresent(String.self, forKey: .connectionId)
        userId = try container.decode(String.self, forKey: .userId)
        email = try container.decode(String.self, forKey: .email)
        displayName = try container.decode(String.self, forKey: .displayName)
        color = try container.decode(Int.self, forKey: .color)
        requestedAt = try container.decode(Int64.self, forKey: .requestedAt)
        guard Self.isSafeIdentityLabel(displayName, maximumCount: 256),
              Self.isSafeIdentityLabel(email, maximumCount: 320) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "Unsafe workspace-share identity label"
            ))
        }
    }

    private static func isSafeIdentityLabel(_ value: String, maximumCount: Int) -> Bool {
        guard !value.isEmpty,
              value.count <= maximumCount,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return !(code <= 0x1F || (0x7F...0x9F).contains(code) ||
                code == 0x061C || (0x200B...0x200F).contains(code) ||
                (0x2028...0x202E).contains(code) || (0x2060...0x2069).contains(code) ||
                code == 0xFEFF)
        }
    }
}
