import Foundation

public enum SocketProtocolVersion: String, Sendable {
    case v1
    case v2
}

public struct SocketCommandLine: Equatable, Sendable {
    public let rawValue: String
    public let trimmedValue: String
    public let protocolVersion: SocketProtocolVersion

    public init?(_ rawValue: String) {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        self.rawValue = rawValue
        self.trimmedValue = trimmedValue
        self.protocolVersion = trimmedValue.hasPrefix("{") ? .v2 : .v1
    }

    public var v1CommandName: String? {
        guard protocolVersion == .v1 else { return nil }
        return trimmedValue.split(separator: " ", maxSplits: 1).first.map { String($0).lowercased() }
    }
}
