import Testing

@testable import CmuxTerminalCore

@Suite struct TerminalGitHubReferenceClickPolicyTests {
    private let policy = TerminalGitHubReferenceClickPolicy()

    /// The column of the first character of `token` in `line`.
    private func column(of token: String, in line: String) -> Int {
        guard let range = line.range(of: token) else {
            Issue.record("\(token) is not in \(line)")
            return 0
        }
        return line.distance(from: line.startIndex, to: range.lowerBound)
    }

    // MARK: Before the repository is known

    /// A reference that names its own repository must open straight away.
    /// Reading `git` to answer a question the token already answered would put
    /// a subprocess in front of every such click.
    @Test func anExplicitSlugOpensWithoutALookup() {
        let line = "see manaflow-ai/cmux#15221 for the detector"
        let decision = policy.decision(
            runtimeOutcome: .unhandled,
            inVisibleLine: line,
            column: column(of: "manaflow-ai", in: line)
        )
        guard case .open(let reference) = decision else {
            Issue.record("expected open, got \(decision)")
            return
        }
        #expect(reference.repositorySlug == "manaflow-ai/cmux")
        #expect(reference.kind == .issueOrPullRequest(number: 15221))
    }

    @Test func aBareReferenceAsksForTheRepository() {
        let line = "fixed in #15221"
        #expect(
            policy.decision(
                runtimeOutcome: .unhandled,
                inVisibleLine: line,
                column: column(of: "#15221", in: line)
            ) == .resolveRepository
        )
    }

    @Test func aCommitSHAAsksForTheRepository() {
        let line = "3da26885653 Bound SHA length"
        #expect(
            policy.decision(
                runtimeOutcome: .unhandled,
                inVisibleLine: line,
                column: 0
            ) == .resolveRepository
        )
    }

    /// The point of the pre-lookup question: an ordinary word must not put a
    /// `git` call behind a cmd-click that was never going to open anything.
    @Test func anOrdinaryWordNeverCostsALookup() {
        let line = "the quick brown fox"
        #expect(
            policy.decision(
                runtimeOutcome: .unhandled,
                inVisibleLine: line,
                column: column(of: "brown", in: line)
            ) == .ignore
        )
    }

    // MARK: Yielding to the runtime

    /// When the terminal runtime already opened a URL, reading a reference out
    /// of the same click opens a second thing. The runtime wins.
    @Test func aRuntimeHandledClickIsNotOurs() {
        let line = "see manaflow-ai/cmux#15221"
        for outcome: TerminalCommandClickRuntimeOutcome in [.openURL, .consumed] {
            #expect(
                policy.decision(
                    runtimeOutcome: outcome,
                    inVisibleLine: line,
                    column: column(of: "manaflow-ai", in: line)
                ) == .ignore,
                "outcome \(outcome) must yield to the runtime"
            )
        }
    }

    @Test func noReadableLineIsIgnored() {
        #expect(
            policy.decision(runtimeOutcome: .unhandled, inVisibleLine: nil, column: 4) == .ignore
        )
    }

    // MARK: After the repository is known

    @Test func aBareReferenceOpensAgainstThePaneRepository() {
        let line = "fixed in #15221"
        let decision = policy.decision(
            inVisibleLine: line,
            column: column(of: "#15221", in: line),
            repositorySlug: "manaflow-ai/cmux"
        )
        #expect(decision == .open(
            TerminalGitHubReference(
                kind: .issueOrPullRequest(number: 15221),
                repositorySlug: "manaflow-ai/cmux",
                rawToken: "#15221"
            )
        ))
    }

    /// A pane with no GitHub remote must not fall back to some other
    /// repository, so a bare `#1` there opens nothing at all.
    @Test func aPaneWithoutAGitHubRemoteOpensNothing() {
        let line = "fixed in #15221"
        #expect(
            policy.decision(
                inVisibleLine: line,
                column: column(of: "#15221", in: line),
                repositorySlug: nil
            ) == .ignore
        )
    }

    /// The lookup is slow enough that the pane can scroll under it. The
    /// post-lookup decision must therefore re-check the captured line rather
    /// than trust that a lookup was requested at all.
    @Test func aLineThatNoLongerReferencesAnythingOpensNothing() {
        #expect(
            policy.decision(
                inVisibleLine: "the quick brown fox",
                column: 4,
                repositorySlug: "manaflow-ai/cmux"
            ) == .ignore
        )
    }
}
