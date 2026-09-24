import Foundation

/// Decrypts the private section of a passphrase-protected OpenSSH key.
enum SSHPrivateKeyDecryption {
    static func decrypt(_ blob: [UInt8], cipher: String, kdfOptions: [UInt8], passphrase: String) throws -> [UInt8] {
        throw SSHPrivateKeyParseError.unsupportedCipher(cipher)
    }
}
