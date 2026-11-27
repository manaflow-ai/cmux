import Foundation

extension CodingUserInfoKey {
    /// Allows app-owned persisted snapshots to decode reserved built-in Vault capabilities.
    static let cmuxTrustedPersistedSessionSnapshot = CodingUserInfoKey(
        rawValue: "com.cmuxterm.session-snapshot.trusted"
    )!
}

extension Decoder {
    var isTrustedCmuxPersistedSessionSnapshot: Bool {
        userInfo[.cmuxTrustedPersistedSessionSnapshot] as? Bool == true
    }
}
