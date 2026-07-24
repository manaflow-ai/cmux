public import Foundation

/// The response returned by notification-feed read mutations.
public struct MobileNotificationFeedMutationResponse: Decodable, Equatable, Sendable {
    /// The number of notifications whose read state changed.
    public let marked: Int
    /// The Mac's feed revision after the mutation.
    public let revision: Int

    /// Decodes a notification-feed mutation response.
    /// - Parameter data: The raw RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error when the payload violates the mutation contract.
    public static func decode(_ data: Data) throws -> MobileNotificationFeedMutationResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
