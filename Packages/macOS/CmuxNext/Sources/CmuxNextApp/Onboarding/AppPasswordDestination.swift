import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation

/// Imported passwords go to the target profile's Chromium password store
/// (`CEFEngine.importPasswords`, fork API 15), the store autofill reads,
/// encrypted with cmux's own "cmux Safe Storage" key. A target id that is not
/// a browser profile is refused, never sent to the default profile instead. Passwords stay
/// `SecretBytes` the whole way: the rows point into them, and they are zeroed
/// as soon as the shim has copied them. With a `hold`, every password stays
/// until the store replies (up to `CEFRuntime.passwordImportTimeout`), since
/// only the reply says which conflict: those are kept for the person's
/// Replace (cx-dwg.6) and the rest are zeroed then. A reply of -1 counts is
/// the store's failure, never counts.
struct AppPasswordDestination: PasswordDestination {
    let available: Bool
    var hold: PasswordConflictHold?
    let write: @MainActor @Sendable (ChromiumPasswordRows, BrowserProfileID) async throws -> ChromiumPasswordWriteResult

    init(available: Bool, hold: PasswordConflictHold? = nil,
         write: @escaping @MainActor @Sendable (ChromiumPasswordRows, BrowserProfileID) async throws -> ChromiumPasswordWriteResult) {
        self.available = available
        self.hold = hold
        self.write = write
    }

    var isAvailable: Bool { available }

    func add(_ logins: [ImportedLogin], toProfile profileID: String) async throws -> PasswordStoreReply {
        guard let profile = BrowserProfileRecord.engineProfile(for: profileID) else { throw PasswordImporter.Failure.storeUnavailable }
        // The password pointers are valid while `logins` is alive; the defer keeps it alive past the write.
        defer { withExtendedLifetime(logins) {} }
        let zeroAll = { for login in logins { login.password.zero() } }
        // The rows (not Sendable) go to the main actor's write with their own afterCopy; the failure paths still use zeroAll.
        let rows = PasswordConflictHold.rows(logins, afterCopy: hold == nil ? { for login in logins { login.password.zero() } } : nil)
        let result: ChromiumPasswordWriteResult
        do {
            result = try await write(rows, profile)
            guard !result.storeFailed else { throw PasswordImporter.Failure.storeUnavailable }
        } catch is CancellationError {
            zeroAll()
            throw CancellationError()
        } catch {
            zeroAll()
            // Chromium not running, its store refused the batch, or no reply in time: no value or site in the reason.
            throw PasswordImporter.Failure.storeUnavailable
        }
        if let hold {
            let conflicts = Set(result.conflictIndices.filter(logins.indices.contains))
            for (index, login) in logins.enumerated() where !conflicts.contains(index) { login.password.zero() }
            await hold.keep(conflicts.sorted().map { logins[$0] }, profile: profile)
        }
        return PasswordStoreReply(added: result.added, duplicate: result.duplicate, conflict: result.conflict, rejected: result.rejected)
    }
}
