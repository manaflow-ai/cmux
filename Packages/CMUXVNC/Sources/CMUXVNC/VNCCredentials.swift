import Foundation

public enum VNCCredentialSource: String, Equatable, Sendable {
    case keychain
    case sessionPassword
    case defaultPassword
}

public struct VNCResolvedCredential: Equatable, Sendable {
    public var username: String
    public var password: String
    public var source: VNCCredentialSource

    public init(username: String, password: String, source: VNCCredentialSource) {
        self.username = username
        self.password = password
        self.source = source
    }
}

public enum VNCCredentialResolver {
    public static func resolve(
        session: MacfleetVNCSession,
        keychainPassword: String?
    ) -> VNCResolvedCredential? {
        if let keychainPassword, !keychainPassword.isEmpty {
            return VNCResolvedCredential(
                username: session.username,
                password: keychainPassword,
                source: .keychain
            )
        }
        if let sessionPassword = session.sessionPassword, !sessionPassword.isEmpty {
            return VNCResolvedCredential(
                username: session.username,
                password: sessionPassword,
                source: .sessionPassword
            )
        }
        if let defaultPassword = session.defaultPassword, !defaultPassword.isEmpty {
            return VNCResolvedCredential(
                username: session.username,
                password: defaultPassword,
                source: .defaultPassword
            )
        }
        return nil
    }
}
