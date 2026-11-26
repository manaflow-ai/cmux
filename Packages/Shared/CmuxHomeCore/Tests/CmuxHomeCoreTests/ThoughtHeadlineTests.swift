import Testing
@testable import CmuxHomeCore

/// The Chief's running indicator narrates a thought by its last bold heading. Review of #22707
/// (projects-7b, 2026-10-21): a last line of asterisks (`*****`, a Markdown rule) passed for a
/// heading, so it hid the real heading above it and the thought had no headline at all.
@MainActor
@Suite struct ThoughtHeadlineTests {
    @Test(arguments: ["*****", "******", "** **", "*** ***", "---", "* * *"])
    func aLineOfAsterisksIsNotAHeading(_ rule: String) {
        #expect("**Checking the tests**\n\nThe suite is slow.\n\n\(rule)".thoughtHeadline == "Checking the tests")
    }

    @Test func aThoughtWithOnlyARuleHasNoHeadline() {
        #expect("*****".thoughtHeadline == nil)
        #expect("Reading the logs.\n\n*****".thoughtHeadline == "Reading the logs")
    }

    @Test func aRealHeadingStillWins() {
        #expect("**First**\n\nbody\n\n**Second step**".thoughtHeadline == "Second step")
        #expect("**Fix *the* bug**".thoughtHeadline == "Fix *the* bug")
    }
}
