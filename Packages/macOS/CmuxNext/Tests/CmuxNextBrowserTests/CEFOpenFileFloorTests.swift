@testable import CmuxNextBrowser
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// Chromium never starts under an open-file limit it would run out of: with a hard limit of 256 the
/// browser process ran out within 6 s of a launch, and Chromium's child launch aborted the whole app
/// (`SeatbeltExecClient: pipe failed`, EMFILE; chaos fuzz row h, cmux21, 2026-10-31). The refusal
/// comes before the framework is mapped, so no Chromium thread runs.
@Suite struct CEFOpenFileFloorTests {
    static func limit(soft: rlim_t, hard: rlim_t) -> OpenFileLimit {
        var limit = OpenFileLimit()
        limit.read = { (soft, hard) }
        return limit
    }

    static var layout: CEFRuntimeLayout {
        let root = URL(filePath: "/tmp/cmux-runtime-open-file-floor", directoryHint: .isDirectory)
        return CEFRuntimeLayout(frameworksDirectory: root, mainBundle: URL(filePath: "/Applications/cmux.app"),
                                helperApp: root.appending(path: "cmux Helper.app"), trust: .downloaded(teamID: "ABCDE12345"))
    }

    @Test func aHardLimitOf256RefusesTheLoad() {
        let result = CEFRuntime.loadLibrary(Self.layout, signatureChecker: AcceptingCEFCodeSignatures(),
                                            openFiles: Self.limit(soft: 256, hard: 256))
        guard case .failure(.openFileLimit(let soft)) = result else {
            Issue.record("Chromium's load went on under an open-file limit of 256: \(result)")
            return
        }
        #expect(soft == 256)
    }

    /// A raised limit does not refuse: the load goes on to its next step (here the missing shim).
    @Test func aRaisedLimitDoesNotRefuse() {
        let result = CEFRuntime.loadLibrary(Self.layout, signatureChecker: AcceptingCEFCodeSignatures(),
                                            openFiles: Self.limit(soft: 61_440, hard: 61_440))
        if case .failure(.openFileLimit) = result { Issue.record("a raised limit refused Chromium") }
    }
}

private struct AcceptingCEFCodeSignatures: CEFCodeSignatureChecking {
    nonisolated func invalidItem(in layout: CEFRuntimeLayout, teamID: String) -> String? { nil }
}
