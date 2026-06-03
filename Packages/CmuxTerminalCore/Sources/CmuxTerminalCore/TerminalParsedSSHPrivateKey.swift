public import NIOSSH

/// A parsed OpenSSH private key plus its OpenSSH-format public key string.
public struct TerminalParsedSSHPrivateKey {
    /// The parsed NIOSSH private key, ready for authentication.
    public let privateKey: NIOSSHPrivateKey
    /// The matching public key in OpenSSH authorized-keys format.
    public let openSSHPublicKey: String

    /// Creates a parsed key pair.
    /// - Parameters:
    ///   - privateKey: The parsed NIOSSH private key.
    ///   - openSSHPublicKey: The matching OpenSSH-format public key string.
    public init(privateKey: NIOSSHPrivateKey, openSSHPublicKey: String) {
        self.privateKey = privateKey
        self.openSSHPublicKey = openSSHPublicKey
    }
}
