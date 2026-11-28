import CmuxNextBrowser
import CmuxNextBrowserImport

/// The sign-ins an import found saved with another password (cx-dwg.6): a
/// CSV, or every source profile of an Import from Browser run (cx-dwg.8),
/// each kept with the profile it was written to. The import never overwrites
/// a saved password; the toast's Replace is the person's explicit choice to
/// save these over the saved ones. Until then the passwords stay in their
/// `SecretBytes`, and they are zeroed once Replace ran or the toast went
/// without it.
@MainActor
final class PasswordConflictHold {
    typealias Replace = @MainActor (ChromiumPasswordRows, BrowserProfileID) async throws -> ChromiumPasswordReplaceResult

    private let write: Replace
    private var batches: [(profile: BrowserProfileID, logins: [ImportedLogin])] = []

    init(replace write: @escaping Replace) {
        self.write = write
    }

    var count: Int { batches.reduce(0) { $0 + $1.logins.count } }

    /// One store write's conflicts, beside any earlier write's.
    func keep(_ logins: [ImportedLogin], profile: BrowserProfileID) {
        guard !logins.isEmpty else { return }
        batches.append((profile, logins))
    }

    /// Saves the held passwords over the saved ones, one write per profile;
    /// they are zeroed as soon as the shim has copied them, or here when a
    /// write fails (also a reply of -1 counts, the store's failure). A
    /// profile whose write fails counts as rejected and the next one still
    /// goes; only when nothing was replaced does the failure throw, so the
    /// result never reads as everything replaced.
    func replace() async throws -> ChromiumPasswordReplaceResult {
        let held = batches
        batches = []
        // The password pointers are valid while `held` is alive; the defer keeps it alive past the writes.
        defer { withExtendedLifetime(held) {} }
        var total = ChromiumPasswordReplaceResult(updated: 0, missing: 0, rejected: 0)
        var failure: (any Error)?
        for batch in held {
            let rows = Self.rows(batch.logins) { for login in batch.logins { login.password.zero() } }
            do {
                let result = try await write(rows, batch.profile)
                guard !result.storeFailed else { throw PasswordImporter.Failure.storeUnavailable }
                total.updated += result.updated
                total.missing += result.missing
                total.rejected += result.rejected
            } catch {
                for login in batch.logins { login.password.zero() }
                failure = failure ?? error
                total.rejected += batch.logins.count
            }
        }
        if let failure, total.updated == 0 { throw failure }
        return total
    }

    /// The toast went without Replace: the saved passwords stay.
    func release() {
        for batch in batches { for login in batch.logins { login.password.zero() } }
        batches = []
    }

    /// Rows pointing into the logins' passwords, which must outlive the write.
    nonisolated static func rows(_ logins: [ImportedLogin], afterCopy: (() -> Void)?) -> ChromiumPasswordRows {
        ChromiumPasswordRows(logins.map { login in
            (url: login.url, signonRealm: login.signonRealm, username: login.username,
             password: login.password.unsafeBytesWhileAlive, created: login.created)
        }, afterCopy: afterCopy)
    }
}
