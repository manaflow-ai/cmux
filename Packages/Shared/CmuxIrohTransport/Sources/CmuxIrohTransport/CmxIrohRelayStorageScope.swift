import CryptoKit
import Foundation

enum CmxIrohRelayStorageScope {
    static func account(_ accountID: String, prefix: String) throws -> String {
        guard CmxIrohPendingRevocation.isSafeAccountID(accountID) else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        let digest = SHA256.hash(data: Data(accountID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest)"
    }

    static func isSafeToken(_ value: String) -> Bool {
        (1 ... 8 * 1_024).contains(value.utf8.count)
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    static func isSafeRelayID(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }
}
