import CmuxNextBrowser
import CmuxNextBrowserImport

/// The sign-ins a CSV import found saved with another password (cx-dwg.6).
/// The import never overwrites a saved password; the toast's Replace is the
/// person's explicit choice to save these over the saved ones. Until then the
/// passwords stay in their `SecretBytes`, and they are zeroed once Replace
/// ran or the toast went without it.
@MainActor
final class PasswordConflictHold {
    typealias Replace = @MainActor (ChromiumPasswordRows, BrowserProfileID) async throws -> ChromiumPasswordReplaceResult

    private let write: Replace
    private var logins: [ImportedLogin] = []
    private var profile: BrowserProfileID?

    init(replace write: @escaping Replace) {
        self.write = write
    }

    var count: Int { logins.count }

    func keep(_ logins: [ImportedLogin], profile: BrowserProfileID) {
        release()
        self.logins = logins
        self.profile = profile
    }

    /// Saves the held passwords over the saved ones; they are zeroed as soon
    /// as the shim has copied them, or here when the write fails.
    func replace() async throws -> ChromiumPasswordReplaceResult {
        let held = logins
        logins = []
        guard let profile, !held.isEmpty else { return ChromiumPasswordReplaceResult(updated: 0, missing: 0, rejected: 0) }
        // The password pointers are valid while `held` is alive; the defer keeps it alive past the write.
        defer { withExtendedLifetime(held) {} }
        let rows = Self.rows(held) { for login in held { login.password.zero() } }
        do {
            return try await write(rows, profile)
        } catch {
            for login in held { login.password.zero() }
            throw error
        }
    }

    /// The toast went without Replace: the saved passwords stay.
    func release() {
        for login in logins { login.password.zero() }
        logins = []
    }

    /// Rows pointing into the logins' passwords, which must outlive the write.
    nonisolated static func rows(_ logins: [ImportedLogin], afterCopy: (() -> Void)?) -> ChromiumPasswordRows {
        ChromiumPasswordRows(logins.map { login in
            (url: login.url, signonRealm: login.signonRealm, username: login.username,
             password: login.password.unsafeBytesWhileAlive, created: login.created)
        }, afterCopy: afterCopy)
    }
}
