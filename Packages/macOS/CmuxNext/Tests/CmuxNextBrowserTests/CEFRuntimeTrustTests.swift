@testable import CmuxNextBrowser
import Foundation
import Testing

/// Downloaded Chromium code is authenticated again at the load boundary;
/// install-time verification is not a permanent trust grant to a writable
/// Application Support folder.
@Suite struct CEFRuntimeTrustTests {
    @Test func aPersistedRuntimeRejectedByTheSignatureCheckerDoesNotLoad() {
        let root = URL(filePath: "/tmp/cmux-runtime-tampered", directoryHint: .isDirectory)
        let layout = CEFRuntimeLayout(
            frameworksDirectory: root,
            mainBundle: URL(filePath: "/Applications/cmux.app"),
            helperApp: root.appending(path: "cmux Helper.app"),
            trust: .downloaded(teamID: "ABCDE12345")
        )

        let result = CEFRuntime.loadLibrary(layout, signatureChecker: RejectingCEFCodeSignatures())
        guard case .failure(.untrusted(let item)) = result else {
            Issue.record("a rejected persisted runtime reached the dynamic loader")
            return
        }
        #expect(item == CEFRuntimeLayout.shimName)
    }

    @Test func aDownloadedRuntimeWithoutASigningTeamDoesNotLoad() {
        let root = URL(filePath: "/tmp/cmux-runtime-unsigned", directoryHint: .isDirectory)
        let layout = CEFRuntimeLayout(
            frameworksDirectory: root,
            mainBundle: URL(filePath: "/Applications/cmux.app"),
            helperApp: root.appending(path: "cmux Helper.app"),
            trust: .downloaded(teamID: nil)
        )

        let result = CEFRuntime.loadLibrary(layout, signatureChecker: RejectingCEFCodeSignatures())
        guard case .failure(.untrusted(let item)) = result else {
            Issue.record("an unsigned downloaded runtime reached the dynamic loader")
            return
        }
        #expect(item == "missing Developer ID team")
    }
}

private struct RejectingCEFCodeSignatures: CEFCodeSignatureChecking {
    nonisolated func invalidItem(in layout: CEFRuntimeLayout, teamID: String) -> String? {
        CEFRuntimeLayout.shimName
    }
}
