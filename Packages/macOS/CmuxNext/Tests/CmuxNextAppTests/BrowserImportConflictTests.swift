import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation
import Testing

/// Import from Browser's conflicts (cx-dwg.8): one run reads several
/// source profiles into one destination, one store write each. Every
/// write's conflicts stay held for the person's Replace, each into the
/// profile it was written to, not only the last write's.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserImportConflictTests {
    private static func login(_ username: String) -> ImportedLogin {
        ImportedLogin(url: "https://example.com/login", signonRealm: "https://example.com/", username: username,
                      password: SecretBytes(copying: Array("throwaway-new".utf8)), created: nil)
    }

    @Test func everySourceProfilesConflictsAreReplacedIntoItsOwnProfile() async throws {
        let other = BrowserProfileID(rawValue: UUID())
        var replaced: [BrowserProfileID] = []
        let hold = PasswordConflictHold { _, profile in
            replaced.append(profile)
            return ChromiumPasswordReplaceResult(updated: 1, missing: 0, rejected: 0)
        }
        // Each write is one sign-in that is saved with another password.
        let destination = AppPasswordDestination(available: true, hold: hold) { _, _ in
            ChromiumPasswordWriteResult(added: 0, duplicate: 0, conflict: 1, rejected: 0, conflictIndices: [0])
        }
        let first = Self.login("first-source")
        let second = Self.login("second-source")
        _ = try await destination.add([first], toProfile: BrowserProfileRecord.defaultID)
        _ = try await destination.add([second], toProfile: BrowserProfileRecord.wireID(for: other))
        #expect(hold.count == 2, "both sources' conflicts are held")

        let result = try await hold.replace()
        #expect(result.updated == 2)
        #expect(replaced == [.default, other], "each source's sign-ins go back into the profile they were imported to")
        #expect(first.password.count == 0 && second.password.count == 0, "every held password is zeroed after the Replace")
    }
}
