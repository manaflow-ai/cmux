import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Import from Browser's conflicts (cx-dwg.8): one run reads several
/// source profiles into one destination, one store write each. Every
/// write's conflicts stay held for the person's Replace, each into the
/// profile it was written to, not only the last write's. The run's toast
/// offers Replace; without it the held passwords are zeroed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .closesItsWindows)
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

    @Test func theRunsToastReplacesOrLetsTheHeldPasswordsGo() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // ARC owns it; close() would release it on top of ARC's references.
        defer { window.close() }
        var writes = 0
        let hold = PasswordConflictHold { _, _ in
            writes += 1
            return ChromiumPasswordReplaceResult(updated: 1, missing: 0, rejected: 0)
        }
        hold.keep([Self.login("first-source")], profile: .default)
        hold.keep([Self.login("second-source")], profile: BrowserProfileID(rawValue: UUID()))

        BrowserImportConflictOffer.offer(hold) { window }
        let toast = { CmuxToastCenter.shared.toasts(in: window).first { $0.id == BrowserImportConflictOffer.toastID } }
        #expect(toast()?.action?.title == PasswordCSVStrings.replace)
        #expect(CmuxToastCenter.shared.runAction(id: BrowserImportConflictOffer.toastID, in: window))
        for _ in 0..<50 where toast()?.message != PasswordCSVStrings.replaced(2) { await Task.yield() }
        #expect(toast()?.message == PasswordCSVStrings.replaced(2))
        #expect(writes == 2 && hold.count == 0)

        let ignored = Self.login("ignored")
        hold.keep([ignored], profile: .default)
        BrowserImportConflictOffer.offer(hold) { window }
        for index in 1...CmuxToastStack.limit {
            CmuxToastCenter.shared.show(CmuxToast(id: "unrelated-\(index)", message: "unrelated \(index)"), in: window)
        }
        #expect(toast() == nil)
        #expect(hold.count == 0 && ignored.password.count == 0, "the toast went without Replace: the held password is zeroed")
        #expect(writes == 2, "nothing was saved over without the person")
    }

    @Test func aProfileWhoseReplaceFailsLeavesTheOthersReplaced() async throws {
        let failing = BrowserProfileID(rawValue: UUID())
        var replaced: [BrowserProfileID] = []
        let hold = PasswordConflictHold { _, profile in
            guard profile != failing else { return ChromiumPasswordReplaceResult(updated: -1, missing: -1, rejected: -1) }
            replaced.append(profile)
            return ChromiumPasswordReplaceResult(updated: 1, missing: 0, rejected: 0)
        }
        let logins = [Self.login("first-source"), Self.login("deleted-profile"), Self.login("third-source")]
        let other = BrowserProfileID(rawValue: UUID())
        hold.keep([logins[0]], profile: .default)
        hold.keep([logins[1]], profile: failing)
        hold.keep([logins[2]], profile: other)

        let result = try await hold.replace()
        #expect(replaced == [.default, other], "the profiles after the failed one are still replaced")
        #expect(result.updated == 2 && result.rejected == 1, "the failed profile's sign-in counts as not replaced")
        #expect(logins.allSatisfy { $0.password.count == 0 }, "every held password is zeroed")
    }
}
