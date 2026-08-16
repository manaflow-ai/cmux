import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite("Terminal command-click arbitrator")
struct TerminalCommandClickArbitratorTests {
    private static let candidate = TerminalWrappedPathResolution(
        path: "/Users/dev/project/TMLlaboratory",
        nativeMatchKeys: [
            "/Users/dev/project/TMLlaborator" + "y",
            "/Users/dev/project/TMLlaborator",
            "y",
        ]
    )

    private static let otherCandidate = TerminalWrappedPathResolution(
        path: "/Users/dev/project/other",
        nativeMatchKeys: ["/Users/dev/project/other-token"]
    )

    // MARK: openURLCallbackResult

    @Test("An explicit scheme always passes through, even with a prepared candidate")
    func explicitSchemePassesThroughOverPreparedCandidate() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: true,
            matchKey: Self.candidate.nativeMatchKeys[0]
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("file: scheme passes through like any other explicit scheme")
    func fileSchemePassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: nil,
            hasExplicitScheme: true,
            matchKey: "file:///Users/dev/project/TMLlaboratory"
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    // Any of the finite `nativeMatchKeys` claims — not just the first
    // (full-candidate) entry. Ghostty's own hard-wrap link continuation can
    // report either the whole joined match or just one row's independent
    // fragment for the same click, and both are legitimate native shapes
    // for the winning direction.
    @Test("An exact match against any of a prepared candidate's finite keys claims the URL", arguments: [0, 1, 2])
    func exactMatchAgainstAnyPreparedKeyClaims(keyIndex: Int) {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: false,
            matchKey: Self.candidate.nativeMatchKeys[keyIndex]
        )
        #expect(result.nextState == .overridePending(Self.candidate))
        #expect(result.shouldClaim == true)
    }

    @Test("A mismatched key against a prepared candidate passes through")
    func mismatchedKeyPassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: false,
            matchKey: Self.otherCandidate.nativeMatchKeys[0]
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    // A fourth, unrelated target and any partial (substring/suffix) variant
    // of a real key must never claim — only an exact match against one of
    // the finite keys does.
    @Test(
        "Unknown or partial targets never claim",
        arguments: [
            "/Users/dev/project/unrelated-fourth-target",
            // A genuine suffix of key[0] that isn't itself equal to any key.
            String("/Users/dev/project/TMLlaboratory".dropFirst(5)),
        ]
    )
    func unknownOrPartialTargetsNeverClaim(matchKey: String) {
        #expect(!Self.candidate.nativeMatchKeys.contains(matchKey))
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: false,
            matchKey: matchKey
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("No prepared state and no scheme still passes through (substring matching is never attempted)")
    func noPreparedStatePassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: nil,
            hasExplicitScheme: false,
            matchKey: "/Users/dev/project/TMLlaboratory"
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("nativePassthrough state never re-claims a later callback")
    func nativePassthroughStateDoesNotClaim() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .nativePassthrough,
            hasExplicitScheme: false,
            matchKey: Self.candidate.nativeMatchKeys[0]
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    // MARK: releaseAction

    @Test("nil final state falls through to the existing word-under-cursor logic")
    func nilFinalStateDefers() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: nil, ghosttyConsumed: false) == .fallThroughToWordUnderCursor
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: nil, ghosttyConsumed: true) == .fallThroughToWordUnderCursor
        )
    }

    @Test("nativePassthrough final state finishes without a fallback open")
    func nativePassthroughFinalStateFinishesWithoutFallback() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: .nativePassthrough, ghosttyConsumed: false) == .finishWithoutFallback
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: .nativePassthrough, ghosttyConsumed: true) == .finishWithoutFallback
        )
    }

    @Test("overridePending opens the candidate regardless of ghosttyConsumed")
    func overridePendingAlwaysOpens() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .overridePending(Self.candidate),
                ghosttyConsumed: false
            ) == .openWrappedCandidate(Self.candidate)
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .overridePending(Self.candidate),
                ghosttyConsumed: true
            ) == .openWrappedCandidate(Self.candidate)
        )
    }

    @Test("prepared opens the candidate only when Ghostty didn't consume the release")
    func preparedOpensOnlyWhenNotConsumed() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .prepared(Self.candidate),
                ghosttyConsumed: false
            ) == .openWrappedCandidate(Self.candidate)
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .prepared(Self.candidate),
                ghosttyConsumed: true
            ) == .finishWithoutFallback
        )
    }

    @Test("prepared and overridePending open through the same action for the same candidate")
    func preparedAndOverridePendingAgreeOnPolicy() {
        // This is the regression this arbitrator exists to prevent: clicking
        // either wrapped row must open exactly once under the same policy,
        // whether or not Ghostty's own link detection fired for the other
        // row.
        let fromTopRowClick = TerminalCommandClickArbitrator.releaseAction(
            finalState: .prepared(Self.candidate),
            ghosttyConsumed: false
        )
        let fromBottomRowClickThatGhosttyPartiallyMatched = TerminalCommandClickArbitrator.releaseAction(
            finalState: .overridePending(Self.candidate),
            ghosttyConsumed: true
        )
        #expect(fromTopRowClick == fromBottomRowClickThatGhosttyPartiallyMatched)
    }
}
