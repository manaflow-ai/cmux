import CmuxNextBrowser
import Foundation

/// The Chromium calls the Passwords page store uses: fork API 18 password core and passkeys
/// through the CEF shim (``CEFEngine``). Tests answer with a fake. Results are the fork's own
/// codes: counts, -1 failed, -2 (username) taken.
@MainActor
protocol ChromiumPasswordCore: AnyObject {
    func canManagePasswords() async -> Bool
    func canManagePasskeys() async -> Bool
    func passwordList(in profile: BrowserProfileID) async throws -> ChromiumPasswordList
    func removePasswords(_ ids: [String], in profile: BrowserProfileID) async throws -> Int
    func removePasswordException(_ id: String, in profile: BrowserProfileID) async throws -> Int
    func setPasswordUsername(_ username: String, id: String, in profile: BrowserProfileID) async throws -> Int
    /// Calls `copy` once with the password bytes, valid only during the call (empty when not
    /// found); `copy` puts them into SecretBytes. False when nothing was revealed.
    func revealPassword(_ id: String, in profile: BrowserProfileID, copy: @escaping (UnsafeRawBufferPointer) -> Void) async throws -> Bool
    func exportPasswords(in profile: BrowserProfileID, to url: URL) async throws -> Int
    func passkeys(in profile: BrowserProfileID) async throws -> [ChromiumPasskey]
    func deletePasskey(_ credentialID: String, in profile: BrowserProfileID) async throws -> Bool
}
