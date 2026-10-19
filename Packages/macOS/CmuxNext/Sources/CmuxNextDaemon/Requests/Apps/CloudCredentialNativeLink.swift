public import Foundation

/// The owned Native socket for one credential scope. A missing socket never permits a global fallback.
public nonisolated struct CloudCredentialNativeLink: Sendable, Equatable {
    public let scope: String
    public let socket: String?

    /// Validates routing metadata; neither the scope nor socket grants authority.
    public init?(scope: String, socket: String?) {
        guard scope.utf8.count == 64, scope.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        if let socket {
            guard socket.hasPrefix("/"), socket.utf8.count <= 103,
                  !socket.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !socket.split(separator: "/").contains("..") else { return nil }
        }
        self.scope = scope; self.socket = socket
    }

    var value: JSONValue {
        .object(["version": .number(1), "scope": .string(scope), "socket": socket.map(JSONValue.string) ?? .null])
    }
}
