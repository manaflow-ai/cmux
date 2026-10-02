import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation

/// Imported passwords go to the target profile's Chromium password store
/// (`CEFEngine.importPasswords`, fork API 15), the store autofill reads,
/// encrypted with cmux's own "cmux Safe Storage" key. A target id that is not
/// a browser profile goes to the default profile. Passwords stay
/// `SecretBytes` the whole way: the rows point into them, and they stay alive
/// until the shim has copied them.
struct AppPasswordDestination: PasswordDestination {
    let available: Bool
    let write: @MainActor @Sendable (ChromiumPasswordRows, BrowserProfileID) async throws -> ChromiumPasswordWriteResult

    var isAvailable: Bool { available }

    func add(_ logins: [ImportedLogin], toProfile profileID: String) async throws -> PasswordStoreReply {
        let profile = BrowserProfileRecord.engineProfile(for: profileID) ?? .default
        // The password pointers are valid while `logins` is alive; the defer keeps it alive past the write.
        defer { withExtendedLifetime(logins) {} }
        let rows = ChromiumPasswordRows(logins.map { login in
            (url: login.url, signonRealm: login.signonRealm, username: login.username,
             password: login.password.unsafeBytesWhileAlive, created: login.created)
        })
        let result: ChromiumPasswordWriteResult
        do {
            result = try await write(rows, profile)
        } catch {
            // Chromium not running or its store refused the batch: no value or site in the reason.
            throw PasswordImporter.Failure.storeUnavailable
        }
        return PasswordStoreReply(added: result.added, duplicate: result.duplicate, conflict: result.conflict, rejected: result.rejected)
    }
}
