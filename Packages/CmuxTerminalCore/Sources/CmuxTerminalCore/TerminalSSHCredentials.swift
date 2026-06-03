public import Foundation

/// The saved SSH credentials (password and/or private key) for a terminal host.
public struct TerminalSSHCredentials: Equatable, Sendable {
    /// The saved SSH password, if any.
    public var password: String?
    /// The saved SSH private key (OpenSSH PEM text), if any.
    public var privateKey: String?

    /// Creates SSH credentials from an optional password and private key.
    /// - Parameters:
    ///   - password: The SSH password, if any.
    ///   - privateKey: The SSH private key text, if any.
    public init(password: String? = nil, privateKey: String? = nil) {
        self.password = password
        self.privateKey = privateKey
    }

    /// Whether a non-empty password is present.
    public var hasPassword: Bool {
        !(password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Whether a non-empty private key is present.
    public var hasPrivateKey: Bool {
        !(privateKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Whether the credentials satisfy the given authentication method.
    /// - Parameter method: The authentication method to check.
    /// - Returns: `true` if a credential for `method` is present.
    public func hasCredential(for method: TerminalSSHAuthenticationMethod) -> Bool {
        switch method {
        case .password:
            hasPassword
        case .privateKey:
            hasPrivateKey
        }
    }

    /// A copy with surrounding whitespace trimmed from each stored credential.
    public var normalized: Self {
        Self(
            password: password?.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKey: privateKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
