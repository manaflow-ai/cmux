import Foundation
import Testing
@testable import CmuxNextOnboarding

/// LAUNCH-NO-TCC-PROMPTS: the onboarding scans use the one protected-folder list
/// (cmux-tui/crates/acpmux/data/protected-folders.json, generated copy).
@Suite struct ProtectedFolderListTests {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    @Test func everyListedFolderHasAPrivacyKind() {
        for entry in ProtectedFolderEntry.inHome + ProtectedFolderEntry.roots {
            #expect(PrivacyFolder(rawValue: entry.kind) != nil, "\(entry.path) has the unknown kind \(entry.kind)")
        }
    }

    @Test func everyListedFolderIsRecognized() {
        for entry in ProtectedFolderEntry.inHome {
            let path = home.appending(path: entry.path).path
            #expect(PrivacyFolder.of(path: path + "/x", home: home)?.rawValue == entry.kind, "\(path)")
        }
        for entry in ProtectedFolderEntry.roots {
            #expect(PrivacyFolder.of(path: entry.path + "/x", home: home)?.rawValue == entry.kind, "\(entry.path)")
        }
        #expect(PrivacyFolder.of(path: home.appending(path: "code/app").path, home: home) == nil)
    }
}
