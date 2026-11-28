import CmuxNextBrowserImport
import Foundation

/// How many secrets a browser profile holds (the profile delete sheet). nil: the build cannot count them.
nonisolated struct PasswordCounts: Sendable, Hashable {
    var passwords: Int?
    var passkeys: Int?
}

/// Why a store call failed.
nonisolated enum PasswordStoreError: Error, Sendable, Equatable {
    /// This build's browser engine has no such call yet (fork password-core API, cmux.18).
    case unavailable
    case notFound
    case failed(String)
}

/// The owner of saved passwords, passkeys and never-save exceptions for the Passwords page
/// (passwords.md section 2: Chromium's store of the cmux browser profile, written only through
/// the fork API in the app process). Profiles are browser profile wire ids
/// (`BrowserProfileRecord.id`). Only the native layer (reveal sheet, pasteboard, export) ever
/// receives a password; the page provider never puts one into a reply.
@MainActor
protocol PasswordStore: AnyObject {
    func capabilities() async -> PasswordStoreCapabilities
    func passwords(profile: String) async throws -> [SavedPassword]
    func passkeys(profile: String) async throws -> [SavedPasskey]
    func exceptions(profile: String) async throws -> [PasswordException]
    /// Removes the sign-ins; answers how many were removed.
    func removePasswords(_ ids: [String], profile: String) async throws -> Int
    func setUsername(_ username: String, id: String, profile: String) async throws
    func removeException(_ id: String, profile: String) async throws -> Bool
    func removePasskey(_ id: String, profile: String) async throws -> Bool
    /// One password for the native reveal sheet or the pasteboard, never for the page.
    func password(_ id: String, profile: String) async throws -> SecretBytes
    /// Writes the profile's passwords as Chromium's CSV to `url` (mode 0600); answers the count.
    func export(profile: String, to url: URL) async throws -> Int
    /// The counts the profile delete sheet names.
    func counts(profile: String) async -> PasswordCounts
    /// Calls `onChange` with the profile id after any change of that profile's store (any
    /// writer). The returned closure stops it.
    func observe(_ onChange: @escaping @MainActor (String) -> Void) -> @MainActor () -> Void
}
