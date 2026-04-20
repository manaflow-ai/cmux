import Foundation

public struct CMUXAuthUser: Codable, Equatable, Sendable {
    public let id: String
    public let primaryEmail: String?
    public let displayName: String?

    public init(id: String, primaryEmail: String?, displayName: String?) {
        self.id = id
        self.primaryEmail = primaryEmail
        self.displayName = displayName
    }
}
