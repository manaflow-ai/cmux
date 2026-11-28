import Foundation

public struct ChangedResponse: Decodable, Sendable, Equatable {
    public var changed: Bool
}
