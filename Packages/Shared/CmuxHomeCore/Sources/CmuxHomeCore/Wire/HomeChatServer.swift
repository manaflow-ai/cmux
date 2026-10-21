public import Foundation

/// Which `cmux.wire/1` server carries DMs and group chats
/// (plans/cmux-next/dm-group-chat-DESIGN.md section 4.5).
public enum HomeChatServer: Hashable, Sendable, Codable {
    case hosted
    case selfHosted(URL)

    /// Why ``selfHostedURL(_:)`` refused an address.
    public enum AddressProblem: Error, Hashable, Sendable {
        case notAURL
        case notTailnet
    }

    /// Not implemented yet: refuses every address.
    public static func selfHostedURL(_ typed: String) throws(AddressProblem) -> URL { throw .notAURL }
}
