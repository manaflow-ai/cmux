import Foundation

/// One bounded broker response page used to assemble an account discovery.
struct CmxIrohDiscoveryPage: Decodable, Sendable {
    static let bindingLimit = 128
    static let legacyBindingLimit = 256
    private static let cursorByteLimit = 256

    let discovery: CmxIrohDiscoveryResponse
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
    }

    init(from decoder: any Decoder) throws {
        let discovery = try CmxIrohDiscoveryResponse(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        let validCursor = nextCursor.map(Self.isSafeCursor) ?? true
        let validCount = if nextCursor == nil {
            discovery.bindings.count <= Self.legacyBindingLimit
        } else {
            discovery.bindings.count == Self.bindingLimit
        }
        guard validCursor, validCount else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Iroh discovery page"
                )
            )
        }
        self.discovery = discovery
        self.nextCursor = nextCursor
    }

    private static func isSafeCursor(_ value: String) -> Bool {
        (1 ... cursorByteLimit).contains(value.utf8.count)
            && value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte)
                    || (65 ... 90).contains(byte)
                    || (97 ... 122).contains(byte)
                    || byte == 45
                    || byte == 95
            }
    }
}
