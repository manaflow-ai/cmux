import Foundation

public struct ComputersSettingsSnapshot: Equatable, Sendable {
    public struct Computer: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let tag: String?
        public let isPaired: Bool
        public let isOnline: Bool?

        public init(id: String, title: String, tag: String?, isPaired: Bool, isOnline: Bool?) {
            self.id = id
            self.title = title
            self.tag = tag
            self.isPaired = isPaired
            self.isOnline = isOnline
        }
    }

    public var computers: [Computer]
    public var isSignedIn: Bool
    public var error: String?

    public init(computers: [Computer] = [], isSignedIn: Bool = false, error: String? = nil) {
        self.computers = computers
        self.isSignedIn = isSignedIn
        self.error = error
    }
}
