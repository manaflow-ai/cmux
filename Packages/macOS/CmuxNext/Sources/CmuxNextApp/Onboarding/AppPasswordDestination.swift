import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation

/// Imported passwords go to the target profile's Chromium password store
/// (`CEFEngine.importPasswords`, fork API 15), the store autofill reads,
/// encrypted with cmux's own "cmux Safe Storage" key. A target id that is not
/// a browser profile is refused (never the default profile). Passwords stay
/// `SecretBytes` the whole way: the rows point into them, and they are zeroed
/// as soon as the shim has copied them.
struct AppPasswordDestination: PasswordDestination {
    let available: Bool
    let write: @MainActor @Sendable (ChromiumPasswordRows, BrowserProfileID) async throws -> ChromiumPasswordWriteResult

    var isAvailable: Bool { available }

    func add(_ logins: [ImportedLogin], toProfile profileID: String) async throws -> PasswordStoreReply {
        guard let profile = BrowserProfileRecord.engineProfile(for: profileID) else { throw PasswordImporter.Failure.storeUnavailable }
        // The password pointers are valid while `logins` is alive; the defer keeps it alive past the write.
        defer { withExtendedLifetime(logins) {} }
        let rows = ChromiumPasswordRows(logins.map { login in
            (url: login.url, signonRealm: login.signonRealm, username: login.username,
             password: login.password.unsafeBytesWhileAlive, created: login.created)
        }, afterCopy: { for login in logins { login.password.zero() } })
        let result: ChromiumPasswordWriteResult
        do {
            result = try await write(rows, profile)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Chromium not running, its store refused the batch, or no reply in time: no value or site in the reason.
            throw PasswordImporter.Failure.storeUnavailable
        }
        return PasswordStoreReply(added: result.added, duplicate: result.duplicate, conflict: result.conflict, rejected: result.rejected)
    }
}
